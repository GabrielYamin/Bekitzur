import ArgumentParser
import BekitzurDomain
import BekitzurPipeline
import Foundation

struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask questions about a Conversation; answers come only from its transcript, with checked quotes."
    )

    @Argument(help: "The Conversation's folder.")
    var conversation: String

    @Argument(help: "Questions, asked in order as one chat.")
    var questions: [String]

    @Flag(help: "Start the chat over before each question, as the app does after five idle minutes; the new chat gets the earlier questions and answers.")
    var startOver = false

    @Flag(help: "Also print the language model's reply, before its quotes are checked.")
    var raw = false

    func run() async throws {
        let folder = URL(filePath: conversation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ConversationInfo.self, from: Data(contentsOf: folder.appending(path: "info.json")))
        let result = try decoder.decode(ProcessedConversation.self, from: Data(contentsOf: folder.appending(path: "result.json")))
        let flags = (try? decoder.decode(TranscriptFlags.self, from: Data(contentsOf: folder.appending(path: "flags.json")))) ?? TranscriptFlags()
        let assistant = ConversationAssistant()
        var earlier: [(question: String, answer: Answer)] = []
        for question in questions {
            if startOver { await assistant.unload(ifIdleFor: 0) }
            let started = Date()
            let answer = try await assistant.ask(
                question, about: info.id, transcript: result.transcript.applying(flags), date: info.startedAt, language: info.language, after: earlier
            )
            earlier.append((question: question, answer: answer))
            print("Q: \(question)")
            if raw { print("   reply: \(await assistant.lastReply)") }
            print("A: \(answer.text ?? "Not in the Conversation.")")
            for evidence in answer.evidence {
                print(String(format: "   [%@ %@] %@: “%@”", evidence.turn, timestamp(evidence.start), evidence.speaker ?? "", evidence.quote))
            }
            log(String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
    }

    private func timestamp(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
