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

    @Test func eachChoiceIsReadBackAsWritten() {
        for language in AppLanguage.allCases {
            let preferences: [String: Any]? = language.codes.map { [AppLanguage.preference: $0] }
            #expect(AppLanguage.chosen(in: preferences) == language)
        }
    }
}
