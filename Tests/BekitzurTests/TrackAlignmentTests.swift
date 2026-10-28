import BekitzurAudio
import Testing

/// Reproducible noise, standing in for speech on the system audio track.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 20_001) / 10_000 - 1
    }

    mutating func samples(_ count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { _ in next() * amplitude }
    }
}

struct TrackAlignmentTests {
    private let rate = 16_000

    /// The microphone's copy of the call through laptop speakers, `shift` samples after the system audio (before it when
    /// negative), with sound of its own.
    private func microphone(hearing system: [Float], shift: Int, gain: Float) -> [Float] {
        var noise = Noise(seed: 2)
        return system.indices.map { i in
            let source = i - shift
            return (system.indices.contains(source) ? gain * system[source] : 0) + noise.next() * 0.02
        }
    }

    /// The October 28 call: the microphone heard the call 60 ms before the system audio track had it. October 21's copy
    /// was upside down.
    @Test(arguments: [Float(0.12), -0.12])
    func aMicrophoneRunningAheadIsPlayedLaterByAsMuch(gain: Float) throws {
        var noise = Noise(seed: 1)
        let system = noise.samples(30 * rate, amplitude: 0.3)

        let delay = try #require(TrackAlignment.microphoneDelay(microphone: microphone(hearing: system, shift: -960, gain: gain), system: system))

        #expect(abs(delay - 0.06) < 1.0 / Double(rate))
    }

    @Test func aCopyHeardAfterTheCallAsFromASpeakerNeedsNoDelay() throws {
        var noise = Noise(seed: 1)
        let system = noise.samples(30 * rate, amplitude: 0.3)

        let lag = try #require(TrackAlignment.copyLag(of: system, in: microphone(hearing: system, shift: 320, gain: 0.12)))

        #expect(abs(lag - 0.02) < 1.0 / Double(rate))
        #expect(TrackAlignment.microphoneDelay(microphone: microphone(hearing: system, shift: 320, gain: 0.12), system: system) == 0)
    }

    @Test func withoutACopyThereIsNothingToLineUp() {
        var callNoise = Noise(seed: 1), roomNoise = Noise(seed: 3)

        let delay = TrackAlignment.microphoneDelay(microphone: roomNoise.samples(30 * rate, amplitude: 0.1), system: callNoise.samples(30 * rate, amplitude: 0.3))

        #expect(delay == nil)
    }
}
