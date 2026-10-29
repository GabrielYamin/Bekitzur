import BekitzurCapture
import Foundation
import Testing

struct CallWatchTests {
    private let slack = ["com.tinyspeck.slackmacgap.helper"]
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func callAppsAndBrowsersAreKnownByTheirHelpersToo() {
        #expect(CallWatch.app(among: ["com.microsoft.teams2"]) == "Teams")
        #expect(CallWatch.app(among: ["org.chromium.Chromium.helper"]) == "Chromium")
        #expect(CallWatch.app(among: ["com.apple.WebKit.GPU"]) == "Safari")
        #expect(CallWatch.app(among: ["com.apple.CoreSpeech"]) == nil)
        #expect(CallWatch.app(among: ["com.google.Chrome.helper", "com.tinyspeck.slackmacgap.helper"]) == "Slack")
    }

    @Test func aCallIsSuggestedOnceItsAppHasKeptTheMicrophoneForAMoment() {
        var watch = CallWatch()

        #expect(watch.update(using: slack, recording: false, now: at(0)) == nil)
        #expect(watch.nextCheck == at(CallWatch.startDelay))
        #expect(watch.update(using: slack, recording: false, now: at(CallWatch.startDelay)) == .record("Slack"))
        #expect(watch.update(using: slack, recording: false, now: at(30)) == nil)
        #expect(watch.nextCheck == nil)
    }

    @Test func aMomentOnTheMicrophoneIsNoCall() {
        var watch = CallWatch()

        _ = watch.update(using: slack, recording: false, now: at(0))
        #expect(watch.update(using: [], recording: false, now: at(1)) == nil)
        #expect(watch.update(using: [], recording: false, now: at(CallWatch.startDelay)) == nil)
        #expect(watch.update(using: [], recording: false, now: at(1 + CallWatch.endDelay)) == nil)
        #expect(watch.call == nil)
    }

    @Test func theEndOfACallBeingRecordedSuggestsStopping() {
        var watch = CallWatch()
        _ = watch.update(using: slack, recording: false, now: at(0))
        _ = watch.update(using: slack, recording: false, now: at(CallWatch.startDelay))

        #expect(watch.update(using: slack, recording: true, now: at(5)) == nil)
        #expect(watch.update(using: [], recording: true, now: at(60)) == nil)
        #expect(watch.nextCheck == at(60 + CallWatch.endDelay))
        #expect(watch.update(using: [], recording: true, now: at(60 + CallWatch.endDelay)) == .stop("Slack"))
        #expect(watch.call == nil)
    }

    @Test func mutingForAWhileIsntTheEndOfTheCall() {
        var watch = CallWatch()
        _ = watch.update(using: slack, recording: true, now: at(0))

        #expect(watch.update(using: [], recording: true, now: at(10)) == nil)
        #expect(watch.update(using: slack, recording: true, now: at(25)) == nil)
        #expect(watch.update(using: [], recording: true, now: at(40)) == nil)
        #expect(watch.update(using: [], recording: true, now: at(59)) == nil)
        #expect(watch.call == "Slack")
    }

    @Test func aCallThatEndsWithoutARecordingSuggestsNothing() {
        var watch = CallWatch()
        _ = watch.update(using: slack, recording: false, now: at(0))
        _ = watch.update(using: slack, recording: false, now: at(CallWatch.startDelay))

        #expect(watch.update(using: [], recording: false, now: at(30)) == nil)
        #expect(watch.update(using: [], recording: false, now: at(30 + CallWatch.endDelay)) == nil)
        #expect(watch.call == nil)
    }

    @Test func aCallInARecordingStartedByHandIsntSuggestedButItsEndIs() {
        var watch = CallWatch()

        #expect(watch.update(using: slack, recording: true, now: at(0)) == nil)
        #expect(watch.update(using: slack, recording: true, now: at(CallWatch.startDelay)) == nil)
        #expect(watch.update(using: [], recording: true, now: at(100)) == nil)
        #expect(watch.update(using: [], recording: true, now: at(100 + CallWatch.endDelay)) == .stop("Slack"))
    }
}
