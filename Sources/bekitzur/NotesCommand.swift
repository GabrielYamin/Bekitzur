import ArgumentParser
import BekitzurDomain
import BekitzurNotes
import BekitzurPipeline
import Foundation

struct NotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Write Notes from a Transcript.",
        discussion: "Input is an engine Transcript (JSON from transcribe --speakers) or a text file of turns like \"[T001] Dana: …\" with optional \"# date:\" and \"# language:\" header lines."
    )

    @Argument(help: "Transcript JSON or turns text file.")
    var input: String

    @Option(help: "Conversation date, YYYY-MM-DD. Defaults to the file's # date: header.")
    var date: String?

    @Option(help: "Notes language: he or en.")
    var notesLanguage: ConversationLanguage = .english

    @Option(help: "Language model file.")
    var model: String = BekitzurPaths.languageModel.path

    @Option(help: "Write the Notes as JSON to this file.")
    var json: String?

    @Option(help: "Write the draft, before the model checked it item by item, as JSON to this file.")
    var draft: String?

    @Option(help: "Most tokens the language model's context grows to; 32768 keeps it at the size it starts with.")
    var maxContext: Int = LanguageModel.maximumContextSize

    func run() async throws {
        let (turns, header) = try loadTurns(URL(filePath: input))
        guard let day = (date ?? header.date).flatMap(parseDay) else {
            throw ValidationError("Give the Conversation date with --date YYYY-MM-DD")
        }
        let model = try LanguageModel(modelURL: URL(filePath: model), largestContext: maxContext)
        let started = Date()
        let (notes, draftNotes, completion) = try NotesWriter(model: model).write(turns: turns, date: day, language: header.language, notesLanguage: notesLanguage)
        try output(notes, completion: completion, json: json)
        if let draft { try writeJSON(draftNotes, to: draft) }
        log(String(format: "Draft and check: %.1f s, in a %d-token context", Date().timeIntervalSince(started), model.contextSize))
    }
}

struct TurnsHeader {
    var date: String?
    var language: ConversationLanguage = .hebrew
}

func loadTurns(_ url: URL) throws -> ([Turn], TurnsHeader) {
    let data = try Data(contentsOf: url)
    if let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
        return (NotesWriter.turns(from: transcript), TurnsHeader(language: transcript.language))
    }
    var header = TurnsHeader()
    var turns: [Turn] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
        if line.hasPrefix("#") {
            let parts = line.dropFirst().split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "date" { header.date = parts[1] }
            if parts.count == 2, parts[0] == "language" { header.language = parts[1].lowercased().hasPrefix("english") ? .english : .hebrew }
        } else if let match = line.firstMatch(of: /^\[(T\d+)\]\s+([^:]+):\s*(.*)$/) {
            turns.append(Turn(id: String(match.1), speaker: String(match.2), text: String(match.3)))
        }
    }
    return (turns, header)
}

func parseDay(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)
}

func output(_ notes: Notes, completion: Completion?, json: String?) throws {
    print("# \(notes.title)\n\n\(notes.summary)\n")
    if !notes.decisions.isEmpty {
        print("Decisions:")
        notes.decisions.forEach { print("- \($0.text) [\($0.sourceTurns.joined(separator: ", "))]") }
    }
    if !notes.actionItems.isEmpty {
        print("Action Items:")
        for item in notes.actionItems {
            let due = item.dueDate.map { " (due \($0))" } ?? item.duePhrase.map { " (\"\($0)\")" } ?? ""
            print("- \(item.owner ?? "Unassigned"): \(item.text)\(due) [\(item.sourceTurns.joined(separator: ", "))]")
        }
    }
    if !notes.openQuestions.isEmpty {
        print("Open Questions:")
        notes.openQuestions.forEach { print("- \($0.text) [\($0.sourceTurns.joined(separator: ", "))]") }
    }
    if let json { try writeJSON(notes, to: json) }
    if let completion {
        log(String(format: "Notes: %d prompt tokens, %d output tokens, %.1f s", completion.promptTokens, completion.outputTokens, completion.seconds))
    }
}

func writeJSON(_ notes: Notes, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(notes).write(to: URL(filePath: path))
}
