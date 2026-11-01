import BekitzurAudio
import BekitzurDomain
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
        let room = roomNoise.samples(30 * rate, amplitude: 0.1), call = callNoise.samples(30 * rate, amplitude: 0.3)

        #expect(TrackAlignment.microphoneDelay(microphone: room, system: call) == nil)
        #expect(TrackAlignment.systemAudioDelays(microphone: room, system: call).isEmpty)
    }

    /// The other side, as the system audio track has it: three seconds of talk, then a second's pause.
    private func talking(seconds: Int) -> [Float] {
        var noise = Noise(seed: 1)
        return (0..<seconds * rate).map { i in (i / rate) % 4 == 3 ? 0 : noise.next() * 0.3 }
    }

    /// November 1: each block lost from the system audio moved the rest of it further ahead of the microphone's copy.
    @Test func systemAudioThatLostABlockPlaysLaterFromThere() throws {
        let call = talking(seconds: 90)
        // A block of 1,024 frames at 48 kHz went missing 41 seconds in; the speakers took 20 ms.
        let lost = 341, at = 41 * rate
        let system = Array(call[..<at] + call[(at + lost)...])

        let delays = TrackAlignment.systemAudioDelays(microphone: microphone(hearing: call, shift: 320, gain: 0.12), system: system)

        try #require(delays.count == 2)
        #expect(delays[0] == TrackDelay(from: 0, delay: 0.02))
        #expect(delays[1].delay == Double(320 + lost) / Double(rate))
        #expect(abs(delays[1].from - 41) < 4)
        // Placed, the system audio is the call as the microphone heard it, away from where the delay changes.
        let placed = TrackAlignment.placing(system, by: delays)
        for second in [10, 30, 60, 80] { #expect(placed[second * rate + 320] == call[second * rate]) }
    }

    /// Speakers and a microphone with clocks of their own, 50 parts per million apart: the copy moves a little at a time,
    /// and the delay follows.
    @Test func aCopyThatDriftsIsFollowedWithinAFewMilliseconds() throws {
        let call = talking(seconds: 300)
        let lag = { (i: Int) in 320 + i / 20_000 }
        var noise = Noise(seed: 2)
        let drifting = call.indices.map { i in (i >= lag(i) ? 0.12 * call[i - lag(i)] : 0) + noise.next() * 0.02 }

        let delays = TrackAlignment.systemAudioDelays(microphone: drifting, system: call)

        #expect(delays.count >= 2)
        for second in stride(from: 30, to: 300, by: 30) {
            let delay = try #require(delays.last { $0.from <= Double(second) }).delay
            #expect(abs(delay - Double(lag(second * rate)) / Double(rate)) <= 0.004)
        }
    }

    @Test func aGrowingDelayLeavesSilenceAndAShrinkingOneCutsTheStart() {
        let pieces = TrackDelay.pieces([TrackDelay(from: 0, delay: -0.05), TrackDelay(from: 10, delay: 0.02), TrackDelay(from: 20, delay: 0.01)], duration: 30)

        let expected: [(source: Range<Double>, at: Double)] = [(0.05..<10, 0), (10..<20, 10.02), (20.01..<30, 20.02)]
        #expect(pieces.count == expected.count)
        for (piece, expected) in zip(pieces, expected) {
            #expect(abs(piece.source.lowerBound - expected.source.lowerBound) < 1e-9)
            #expect(piece.source.upperBound == expected.source.upperBound)
            #expect(abs(piece.at - expected.at) < 1e-9)
        }
    }
}
