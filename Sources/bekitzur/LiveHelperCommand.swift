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

    @Argument(help: "Conversation language: he, en, or auto to detect it from the first speech.")
    var language: LanguageChoice

    @Option(help: "Speech model file, instead of the language's.")
    var model: String?

    @Flag(help: "Transcribe every chunk whole, without detecting where people speak.")
    var wholeChunks = false

    func validate() throws {
        if model != nil, language.language == nil { throw ValidationError("--model needs a language") }
    }

    func run() throws {
        let status = LiveTranscriptionHelper.serve(language: language.language, model: model.map { URL(filePath: $0) }, detectsSpeech: !wholeChunks)
        if status != 0 { throw ExitCode(status) }
    }
}
