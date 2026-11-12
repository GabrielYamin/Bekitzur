import ArgumentParser
import BekitzurDomain
import BekitzurPipeline
import Foundation

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Chat about a Conversation: answers come only from its transcript and Notes, with checked quotes, and the Notes change when asked. Nothing is saved.",
        aliases: ["ask"]
    )

    @Argument(help: "The Conversation's folder, or a text file of turns like \"[T001] Dana: …\" with optional \"# date:\" and \"# language:\" header lines.")
    var conversation: String

    @Argument(help: "Messages, sent in order as one chat.")
    var messages: [String]

    @Flag(help: "Start the chat over before each message, as the app does after five idle minutes; the new chat gets the earlier messages and answers.")
    var startOver = false

    @Flag(help: "Also print the language model's reply, before its quotes are checked.")
    var raw = false

    @Flag(help: "Print the Notes as the chat left them.")
    var notes = false

    @Option(help: "Another Conversation's folder, whose Notes the first message brings in, as picking it from the chat's menu does.")
    var with: String?

    @Flag(help: "Don't let messages find the other Conversations in the same folder by who was there and when.")
    var alone = false

    func run() async throws {
        let url = URL(filePath: conversation, directoryHint: .checkFileSystem)
        var (id, transcript, date, current) = try load(url)
        let others = alone || !url.hasDirectoryPath ? nil : Self.conversations(beside: url, except: id)
        var attached = try with.map { try Self.reference(to: URL(filePath: $0, directoryHint: .isDirectory)) }
        let assistant = ConversationAssistant()
        var earlier: [ChatExchange] = []
        for message in messages {
            if startOver { await assistant.unload(ifIdleFor: 0) }
            let started = Date()
            var exchange = ChatExchange(message: message)
            let reply: ChatReply
            do {
                reply = try await assistant.send(
                    message, about: id, transcript: transcript, notes: current, date: date, language: transcript.language, after: earlier,
                    bringing: attached, from: attached == nil ? others : nil
                )
            } catch let error as ChatError {
                exchange.failure = error.localizedDescription
                earlier.append(exchange)
                print("> \(message)\n   \(error.localizedDescription)")
                continue
            }
            attached = nil
            exchange.answer = reply.answer
            exchange.edits = reply.edits
            exchange.reply = reply.raw
            exchange.reference = reply.reference
            if let changed = reply.notes {
                exchange.notesBefore = current
                exchange.notesAfter = changed
                current = changed
            }
            earlier.append(exchange)
            print("> \(message)")
            if raw { print("   reply: \(await assistant.lastReply)") }
            if let reference = reply.reference { print("   from \(reference.id): \(reference.title)") }
            if let text = reply.answer.text {
                print(text)
            } else if reply.edits.isEmpty {
                print("Not in the Conversation.")
            }
            for evidence in reply.answer.evidence {
                print(String(format: "   [%@ %@] %@: “%@”", evidence.turn, timestamp(evidence.start), evidence.speaker ?? "", evidence.quote))
            }
            for edit in reply.edits {
                print("   \(edit.kind.rawValue) \(edit.section?.rawValue ?? ""): \(edit.text)")
            }
            log(String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
        if notes { try output(current, completion: nil, json: nil) }
    }

    /// A Conversation's Transcript with the user's fixes and its Notes, or a turns file as a Transcript of one segment per
    /// turn, without Notes.
    private func load(_ url: URL) throws -> (id: String, transcript: Transcript, date: Date, notes: Notes) {
        guard url.hasDirectoryPath else {
            let (turns, header) = try loadTurns(url)
            let segments = turns.enumerated().map { index, turn in
                TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9), text: turn.text, speaker: turn.speaker, words: nil)
            }
            return (url.lastPathComponent, Transcript(language: header.language, segments: segments), header.date.flatMap(parseDay) ?? Date(), Notes())
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ConversationInfo.self, from: Data(contentsOf: url.appending(path: "info.json")))
        let result = try decoder.decode(ProcessedConversation.self, from: Data(contentsOf: url.appending(path: "result.json")))
        let flags = (try? decoder.decode(TranscriptFlags.self, from: Data(contentsOf: url.appending(path: "flags.json")))) ?? TranscriptFlags()
        return (info.id, result.transcript.applying(flags), info.startedAt, result.notes)
    }

    /// The other Conversations with Notes in the folder `url` is in, newest first, with who was there.
    private static func conversations(beside url: URL, except id: String) -> OtherConversations {
        let folder = url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let candidates = items.compactMap { item -> ChatCandidate? in
            guard let reference = try? Self.reference(to: item), reference.id != id else { return nil }
            return ChatCandidate(id: reference.id, title: reference.title, date: reference.date, people: reference.people)
        }
        return OtherConversations(candidates: candidates.sorted { $0.date > $1.date }) { other in
            try? Self.reference(to: folder.appending(path: other, directoryHint: .isDirectory)).notes
        }
    }

    private static func reference(to url: URL) throws -> ChatReference {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ConversationInfo.self, from: Data(contentsOf: url.appending(path: "info.json")))
        guard info.status == .unreviewed || info.status == .reviewed else { throw ChatError.conversationNotFound }
        let result = try decoder.decode(ProcessedConversation.self, from: Data(contentsOf: url.appending(path: "result.json")))
        let candidate = ChatCandidate(
            id: info.id, title: info.title ?? result.notes.title, date: info.startedAt, people: SearchEntry(result, user: "").people.sorted()
        )
        return ChatReference(candidate, notes: result.notes)
    }

    private func timestamp(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
