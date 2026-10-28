import ArgumentParser
import BekitzurDomain
import Foundation

@main
struct Bekitzur: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Runs the Bekitzur engine on audio files.",
        subcommands: [
            ProcessCommand.self, Transcribe.self, Enroll.self, SpeakersCommand.self, AlignCommand.self, NotesCommand.self, VocabularyCommand.self,
            AudioCheckCommand.self, EnglishTermsCommand.self, LiveHelperCommand.self, SpeechCommand.self, AskCommand.self,
        ]
    )
}

extension ConversationLanguage: ExpressibleByArgument {}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
