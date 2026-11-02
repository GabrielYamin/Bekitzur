import Testing
@testable import BekitzurSpeakers

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

struct TalkingOverTests {
    private let rate = 16_000

    /// The other side for 30 seconds: three seconds of talk, then a second's pause.
    private func otherSide() -> [Float] {
        var noise = Noise(seed: 1)
        return (0..<30 * rate).map { i in (i / rate) % 4 == 3 ? 0 : noise.next() * 0.3 }
    }

    /// What the microphone hears: the other side through laptop speakers and the room at `gain`, the user from 9.2 to
    /// 10.4 seconds while the other side talks, and the room's noise.
    private func microphone(hearing system: [Float], gain: Float, userTalks: Bool) -> [Float] {
        var user = Noise(seed: 5), room = Noise(seed: 9)
        let user1 = Int(9.2 * Double(rate)), user2 = Int(10.4 * Double(rate))
        return system.indices.map { i in
            var sample = room.next() * 0.001
            for (delay, level) in [(3, Float(1)), (80, 0.4), (480, 0.2)] where i >= delay { sample += gain * level * system[i - delay] }
            if userTalks, (user1..<user2).contains(i) { sample += user.next() * 0.3 }
            return sample
        }
    }

    private func seconds(_ stretches: [ClosedRange<Double>]) -> Double {
        stretches.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    /// November 2: two short replies said over the other person went to that person, since the microphone was silenced
    /// all the while they spoke.
    @Test func theUserTalkingOverTheOtherSideIsFound() throws {
        let system = otherSide()

        let found = TalkingOver.stretches(microphone: microphone(hearing: system, gain: 0.1, userTalks: true), system: system)

        let stretch = try #require(found.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound })
        #expect(abs(stretch.lowerBound - 9.2) < 0.15 && abs(stretch.upperBound - 10.4) < 0.15)
        #expect(seconds(found) - seconds([stretch]) < 0.2)
    }

    @Test func theSpeakersCopyAloneIsNotTheUser() {
        let system = otherSide()

        let found = TalkingOver.stretches(microphone: microphone(hearing: system, gain: 0.7, userTalks: false), system: system)

        #expect(seconds(found) < 0.1)
    }

    @Test func withHeadphonesTheUserTalkingOverIsFoundToo() throws {
        let system = otherSide()

        let found = TalkingOver.stretches(microphone: microphone(hearing: system, gain: 0, userTalks: true), system: system)

        let stretch = try #require(found.first)
        #expect(found.count == 1)
        #expect(abs(stretch.lowerBound - 9.2) < 0.15 && abs(stretch.upperBound - 10.4) < 0.15)
    }

    @Test func whereTheUserTalksOverTheOtherSideIsntSilenced() {
        let stretches = SpeakerSeparation.removing([2.0...3.0, 7.5...8.0, 20...21], from: [1.0...5.0, 6.0...9.0])

        #expect(stretches == [1.0...2.0, 3.0...5.0, 6.0...7.5, 8.0...9.0])
    }
}
