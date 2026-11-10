import BekitzurDomain
import Testing

/// The language Bekitzur shows itself in, as the app's own preferences say.
struct AppLanguageTests {
    @Test func withoutAChoiceItFollowsTheMac() {
        #expect(AppLanguage.chosen(in: nil) == .mac)
        #expect(AppLanguage.chosen(in: [:]) == .mac)
    }

    /// System Settings writes a region along with the language, and macOS lists languages in order of preference.
    @Test func theFirstLanguageChosenIsTheOne() {
        #expect(AppLanguage.chosen(in: [AppLanguage.preference: ["he-IL"]]) == .hebrew)
        #expect(AppLanguage.chosen(in: [AppLanguage.preference: ["en-US", "he"]]) == .english)
    }

    @Test func aLanguageWithoutATranslationFollowsTheMac() {
        #expect(AppLanguage.chosen(in: [AppLanguage.preference: ["fr"]]) == .mac)
    }

    /// The language alone switches the text but leaves the layout left to right.
    @Test func hebrewGoesRightToLeft() {
        #expect(AppLanguage.hebrew.rightToLeft == true)
        #expect(AppLanguage.english.rightToLeft == false)
        #expect(AppLanguage.mac.rightToLeft == nil)
    }

    @Test func aChoiceShowsOnceTheAppRestarts() {
        #expect(AppLanguage.english.needsRestart(launchedIn: .hebrew, rightToLeft: true))
        #expect(AppLanguage.mac.needsRestart(launchedIn: .hebrew, rightToLeft: true))
        #expect(!AppLanguage.hebrew.needsRestart(launchedIn: .hebrew, rightToLeft: true))
        #expect(!AppLanguage.mac.needsRestart(launchedIn: .mac, rightToLeft: nil))
    }

    /// Hebrew chosen in System Settings, or by a version that didn't set the direction, launches left to right; the
    /// direction is set then, for the next launch.
    @Test func hebrewLaidOutLeftToRightNeedsARestart() {
        #expect(AppLanguage.hebrew.needsRestart(launchedIn: .hebrew, rightToLeft: nil))
        #expect(AppLanguage.hebrew.needsRestart(launchedIn: .hebrew, rightToLeft: false))
    }

    @Test func eachChoiceIsReadBackAsWritten() {
        for language in AppLanguage.allCases {
            let preferences: [String: Any]? = language.codes.map { [AppLanguage.preference: $0] }
            #expect(AppLanguage.chosen(in: preferences) == language)
        }
    }
}
