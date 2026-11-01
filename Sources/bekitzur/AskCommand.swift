import ArgumentParser
import BekitzurDomain
import BekitzurPipeline
import Foundation

struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask questions about a Conversation; answers come only from its transcript, with checked quotes."
    )

    @Argument(help: "The Conversation's folder, or a text file of turns like \"[T001] Dana: …\" with optional \"# date:\" and \"# language:\" header lines.")
    var conversation: String

    @Argument(help: "Questions, asked in order as one chat.")
    var questions: [String]

    @Flag(help: "Start the chat over before each question, as the app does after five idle minutes; the new chat gets the earlier questions and answers.")
    var startOver = false

    @Flag(help: "Also print the language model's reply, before its quotes are checked.")
    var raw = false

    func run() async throws {
        let (id, transcript, date) = try load(URL(filePath: conversation, directoryHint: .checkFileSystem))
        let assistant = ConversationAssistant()
        var earlier: [(question: String, answer: Answer)] = []
        for question in questions {
            if startOver { await assistant.unload(ifIdleFor: 0) }
            let started = Date()
            let answer = try await assistant.ask(question, about: id, transcript: transcript, date: date, language: transcript.language, after: earlier)
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

    /// A Conversation's Transcript with the user's fixes, or a turns file as a Transcript of one segment per turn.
    private func load(_ url: URL) throws -> (id: String, transcript: Transcript, date: Date) {
        guard url.hasDirectoryPath else {
            let (turns, header) = try loadTurns(url)
            let segments = turns.enumerated().map { index, turn in
                TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9), text: turn.text, speaker: turn.speaker, words: nil)
            }
            return (url.lastPathComponent, Transcript(language: header.language, segments: segments), header.date.flatMap(parseDay) ?? Date())
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ConversationInfo.self, from: Data(contentsOf: url.appending(path: "info.json")))
        let result = try decoder.decode(ProcessedConversation.self, from: Data(contentsOf: url.appending(path: "result.json")))
        let flags = (try? decoder.decode(TranscriptFlags.self, from: Data(contentsOf: url.appending(path: "flags.json")))) ?? TranscriptFlags()
        return (info.id, result.transcript.applying(flags), info.startedAt)
    }

    private func timestamp(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
