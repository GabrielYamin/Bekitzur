import ArgumentParser
import BekitzurDomain
import BekitzurPipeline
import Foundation

@main
struct Bekitzur: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Runs the Bekitzur engine on audio files.",
        subcommands: [
            ProcessCommand.self, Transcribe.self, Enroll.self, SpeakersCommand.self, AlignCommand.self, LanguageCommand.self, NotesCommand.self, VocabularyCommand.self,
            AudioCheckCommand.self, EnglishTermsCommand.self, LiveHelperCommand.self, SpeechCommand.self, AskCommand.self, ModelsCommand.self,
        ]
    )
}

extension ConversationLanguage: ExpressibleByArgument {}

/// he, en, or auto to detect the language.
struct LanguageChoice: ExpressibleByArgument {
    /// Nil to detect it.
    var language: ConversationLanguage?

    init(_ language: ConversationLanguage?) {
        self.language = language
    }

    init?(argument: String) {
        guard argument == LiveTranscriptionHelper.detect || ConversationLanguage(rawValue: argument) != nil else { return nil }
        language = ConversationLanguage(rawValue: argument)
    }

    var argument: String { language?.rawValue ?? LiveTranscriptionHelper.detect }
    var defaultValueDescription: String { argument }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
