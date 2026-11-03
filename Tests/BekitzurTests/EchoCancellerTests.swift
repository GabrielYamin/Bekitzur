import Accelerate
import BekitzurAudio
import Testing

/// Reproducible noise, standing in for speech.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 20_001) / 10_000 - 1
    }
}

struct EchoCancellerTests {
    private let rate = 16_000

    /// The other side for 30 seconds: three seconds of talk, then a second's pause.
    private func otherSide() -> [Float] {
        var noise = Noise(seed: 1)
        return (0..<30 * rate).map { i in (i / rate) % 4 == 3 ? 0 : noise.next() * 0.3 }
    }

    private func user(from start: Double, to end: Double) -> [Float] {
        var noise = Noise(seed: 5)
        return (0..<30 * rate).map { i in (Int(start * Double(rate))..<Int(end * Double(rate))).contains(i) ? noise.next() * 0.3 : 0 }
    }

    /// What laptop speakers and the room make of `system` in the microphone, at `gain`, with the room's noise.
    private func copy(of system: [Float], gain: Float) -> [Float] {
        var room = Noise(seed: 9)
        return system.indices.map { i in
            var sample = room.next() * 0.001
            for (delay, level) in [(3, Float(1)), (80, 0.4), (480, 0.2)] where i >= delay { sample += gain * level * system[i - delay] }
            return sample
        }
    }

    private func power(_ x: [Float], from start: Double, to end: Double) -> Float {
        vDSP.meanSquare(x[Int(start * Double(rate))..<Int(end * Double(rate))])
    }

    @Test func withoutTheOtherSideTheMicrophoneComesBackAsItWas() {
        let microphone = user(from: 2, to: 9).enumerated().map { $0.element + Float($0.offset % 7) * 1e-4 }

        let cleaned = EchoCanceller.cancel(microphone: microphone, system: [Float](repeating: 0, count: microphone.count)).microphone

        #expect(cleaned.count == microphone.count)
        #expect(zip(cleaned, microphone).map { abs($0 - $1) }.max() ?? 1 < 1e-4)
    }

    @Test func speechIsOnlyWhereSomeoneTalks() {
        let microphone = user(from: 2, to: 9).enumerated().map { $0.element + Float($0.offset % 7) * 1e-4 }

        let speech = EchoCanceller.cancel(microphone: microphone, system: [Float](repeating: 0, count: microphone.count)).speech()

        #expect(speech.count == 1)
        #expect(abs((speech.first?.lowerBound ?? 0) - 2) < 0.06)
        #expect(abs((speech.first?.upperBound ?? 0) - 9) < 0.06)
    }

    /// The speakers' copy can be only 2 dB quieter than the system audio.
    @Test func theSpeakersCopyIsTakenOut() {
        let system = otherSide()
        let microphone = copy(of: system, gain: 0.7)

        let cleaned = EchoCanceller.cancel(microphone: microphone, system: system).microphone

        #expect(10 * log10(power(cleaned, from: 4, to: 7) / power(microphone, from: 4, to: 7)) < -15)
    }

    @Test func someoneTalkingOverTheOtherSideStays() {
        let system = otherSide(), speech = user(from: 9.2, to: 10.4)
        let microphone = zip(copy(of: system, gain: 0.3), speech).map(+)

        let result = EchoCanceller.cancel(microphone: microphone, system: system)

        // Their speech keeps its level, within the copy left over; the copy alone is gone.
        #expect(abs(10 * log10(power(result.microphone, from: 9.3, to: 10.3) / power(speech, from: 9.3, to: 10.3))) < 2)
        #expect(power(result.microphone, from: 4, to: 7) < 0.05 * power(microphone, from: 4, to: 7))
        let own = result.ownSpeech()
        let frame = { (seconds: Double) in Int(seconds / EchoCanceller.Result.frameSeconds) - 1 }
        #expect(own[frame(9.4)...frame(10.2)].allSatisfy { $0 })
        #expect(own[frame(4)...frame(7)].filter { $0 }.count < 5)
        let stretches = result.speech()
        #expect(stretches.contains { $0.lowerBound <= 9.4 && 10.2 <= $0.upperBound })
        #expect(!stretches.contains { $0.overlaps(4...7) })
    }
}
