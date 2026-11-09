import BekitzurAudio
import BekitzurModels
import BekitzurNotes
import BekitzurPipeline
import BekitzurUpdates
import Foundation
import Testing

/// The app's translations, in App/Resources: a translation whose placeholders differ from its key's shows the wrong
/// value, or crashes when it's formatted.
struct LocalizationTests {
    private static let resources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../App/Resources").standardized

    private static func strings(_ file: String) throws -> [String: String] {
        let url = resources.appending(path: file)
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(file) isn't a strings file")
    }

    private static func placeholders(_ text: String) -> [String] {
        let pattern = /%(?:\d+\$)?(?:lld|ld|d|@|lf|f)/
        return text.matches(of: pattern).map { String($0.output) }.sorted()
    }

    @Test func eachHebrewTranslationHasItsKeysPlaceholders() throws {
        let hebrew = try Self.strings("he.lproj/Localizable.strings")

        #expect(hebrew.count > 300)
        for (key, value) in hebrew {
            #expect(Self.placeholders(value) == Self.placeholders(key), "\(key)")
        }
    }

    @Test func thePermissionPromptsAreTranslated() throws {
        let hebrew = try Self.strings("he.lproj/InfoPlist.strings")

        #expect(hebrew["NSMicrophoneUsageDescription"] != nil)
        #expect(hebrew["NSAudioCaptureUsageDescription"] != nil)
    }

    /// macOS offers a language for an app only when the app has a folder for it, English too.
    @Test func englishIsALanguageOfItsOwn() throws {
        #expect(try Self.strings("en.lproj/Localizable.strings").isEmpty)
    }

    /// The app shows an error in its own words, translated, where macOS would say only "The operation couldn't be
    /// completed"; in English they're the words the log has, though numbers from 1,000 up are grouped.
    @Test(arguments: [
        ProcessingError.noAudio, ProcessingError.noSpeech, ProcessingError.transcriptionStopped,
        UpdateError.unreachable(503), UpdateError.unsigned, UpdateError.checksum, UpdateError.noApp, UpdateError.notBekitzur(-67050),
        UpdateError.unzip(1), UpdateError.notWritable(URL(filePath: "/Applications")),
        ModelDownloadError.unreachable(404),
        LanguageModelError.modelNotLoaded(URL(filePath: "/tmp/model.gguf")), LanguageModelError.contextNotCreated,
        LanguageModelError.invalidGrammar, LanguageModelError.promptTooLong(tokens: 900, limit: 512), LanguageModelError.decodeFailed(-1),
        NotesWriterError.unreadableOutput("{\"title\":"),
        AudioLoaderError.unsupportedFormat(URL(filePath: "/tmp/a.m4a")), AudioLoaderError.conversionFailed(URL(filePath: "/tmp/a.m4a"), "no frames"),
    ] as [any Error])
    func anErrorShowsItsOwnWords(_ error: any Error) {
        #expect(error.localizedDescription == String(describing: error))
    }
}
