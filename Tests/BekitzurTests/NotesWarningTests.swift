import BekitzurDomain
import Testing

/// What a Conversation's Notes miss because of its audio, saved in English with it and shown in the app's language.
struct NotesWarningTests {
    @Test(arguments: [
        NotesWarning.callUnreadable, .microphoneUnreadable, .noComputerAudio, .silentMicrophone, .liveTranscriptOnly(minutes: 12),
    ])
    func eachWarningIsReadBackAsSaved(_ warning: NotesWarning) {
        #expect(NotesWarning(saved: warning.saved) == warning)
    }

    /// Conversations keep the warnings that earlier versions saved, in these words.
    @Test func warningsSavedBeforeAreRead() {
        #expect(NotesWarning(saved: "Your microphone recorded only silence. Check the input device in System Settings → Sound.") == .silentMicrophone)
        #expect(
            NotesWarning(saved: "The audio couldn't be read, so these Notes come from the live Transcript of the first 3 minutes, without Speakers.")
                == .liveTranscriptOnly(minutes: 3)
        )
    }

    /// One saved in another language, or one this version doesn't know, shows as it was saved.
    @Test func aWarningItDoesntKnowIsntRead() {
        #expect(NotesWarning(saved: "המיקרופון הקליט רק שקט.") == nil)
        #expect(NotesWarning(saved: "The audio couldn't be read, so these Notes come from the live Transcript of the first 3 minutes.") == nil)
    }
}
