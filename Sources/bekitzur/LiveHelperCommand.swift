import ArgumentParser
import BekitzurDomain
import BekitzurPipeline
import Foundation

struct LiveHelperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live-helper",
        abstract: "Transcribes live chunks from standard input, as the app's helper process does; used by transcribe --live.",
        shouldDisplay: false
    )

    @Argument(help: "Speech model file.")
    var model: String

    @Argument(help: "Conversation language: he or en.")
    var language: ConversationLanguage

    @Flag(help: "Transcribe every chunk whole, without detecting where people speak.")
    var wholeChunks = false

    func run() throws {
        let status = LiveTranscriptionHelper.serve(modelURL: URL(filePath: model), language: language, detectsSpeech: !wholeChunks)
        if status != 0 { throw ExitCode(status) }
    }
}
