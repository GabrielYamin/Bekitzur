import Testing
@testable import BekitzurCapture

/// A microphone that stops sending audio is started again from scratch, the user hears of it when that doesn't help,
/// and it's tried again less and less often until audio comes back.
struct MicrophoneSilenceTests {
    /// Checks once a second, as the recorder does, through seconds `first...last` without audio.
    private func check(_ silence: inout MicrophoneSilence, _ seconds: ClosedRange<Int>, restarting: Bool = false) -> [Int: [MicrophoneSilence.Action]] {
        var taken: [Int: [MicrophoneSilence.Action]] = [:]
        for second in seconds {
            let actions = silence.check(quiet: Double(second), now: Double(second), restarting: restarting)
            if !actions.isEmpty { taken[second] = actions }
        }
        return taken
    }

    @Test func audioComingLeavesItAlone() {
        var silence = MicrophoneSilence()
        var actions: [MicrophoneSilence.Action] = []
        for second in 0..<60 { actions += silence.check(quiet: 0.1, now: Double(second), restarting: false) }
        #expect(actions.isEmpty)
    }

    @Test func noAudioStartsItAgainThenTellsTheUser() {
        var silence = MicrophoneSilence()
        let taken = check(&silence, 1...9)
        let expected: [Int: [MicrophoneSilence.Action]] = [4: [.rebuild], 8: [.silent(after: 8)]]
        #expect(taken == expected)
    }

    @Test func whileSilentItTriesAgainLessAndLessOften() {
        var silence = MicrophoneSilence()
        let taken = check(&silence, 1...200)
        let rebuilds = taken.filter { $0.value.contains(.rebuild) }.keys.sorted()
        let expected = [4, 14, 34, 74, 134, 194]
        #expect(rebuilds == expected)
    }

    @Test func aRestartUnderWayGoesFirst() {
        var silence = MicrophoneSilence()
        let waiting = check(&silence, 1...6, restarting: true)
        let after = silence.check(quiet: 7, now: 7, restarting: false)
        #expect(waiting.isEmpty)
        #expect(after == [.rebuild])
    }

    /// Pointing an engine at a device that sends nothing is itself a change, so its restarts can go on and on.
    @Test func aRestartThatNeverSettlesDoesntKeepTheUserFromHearing() {
        var silence = MicrophoneSilence()
        let taken = check(&silence, 1...9, restarting: true)
        let expected: [Int: [MicrophoneSilence.Action]] = [8: [.rebuild, .silent(after: 8)]]
        #expect(taken == expected)
    }

    @Test func audioComingBackIsSaid() {
        var silence = MicrophoneSilence()
        _ = check(&silence, 1...12)
        let back = silence.check(quiet: 0.2, now: 13, restarting: false)
        let then = silence.check(quiet: 0.2, now: 14, restarting: false)
        #expect(back == [.hearing(after: 12)])
        #expect(then.isEmpty)
        #expect(!silence.silent)
    }

    /// Started again before the user heard of it, a microphone whose audio comes back is logged as such.
    @Test func startingAgainThatBringsAudioBackIsSaidToo() {
        var silence = MicrophoneSilence()
        _ = check(&silence, 1...5)
        let back = silence.check(quiet: 0.1, now: 6, restarting: false)
        #expect(back == [.hearing(after: 5)])
    }
}
