import BekitzurDomain
import BekitzurNotes
import CryptoKit
import Foundation

extension MCPServer {
    enum Tool: String, CaseIterable {
        case findConversations = "find_conversations"
        case listPeople = "list_people"
        case getConversation = "get_conversation"
        case getTranscript = "get_transcript"
        case editNotes = "edit_notes"
    }

    /// What went wrong with a tool's arguments, told to the model so it can do better.
    struct ToolFailure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    static let instructions = """
    Bekitzur records the user's work conversations, meetings and calls, on their Mac, and writes Notes for each from a \
    Transcript of who said what: a summary, Decisions, Action Items with their Owners and due dates, and Open Questions. \
    find_conversations finds Conversations by words, person, or date; get_conversation gives one's Notes, and \
    get_transcript what was said. Conversations are often in Hebrew with English terms, and speakers are named people \
    or unnamed voices like "Speaker 2". Answer from the Notes and the Transcript, quoting the Transcript as it is. \
    edit_notes changes a Conversation's Notes when the user asks; the user sees each change in Bekitzur, with Undo.
    """

    static let notAllowed = """
    Bekitzur doesn't let AI apps use the user's Conversations. Ask the user to turn on "Let AI apps use your \
    Conversations" in Bekitzur's Settings, under AI apps, then try again.
    """

    /// The tools as the protocol describes them, read from JSON.
    static var tools: [Any] {
        (try? JSONSerialization.jsonObject(with: Data(toolsJSON.utf8))) as? [Any] ?? []
    }

    /// The tools and their arguments, for an AI agent that runs them from its terminal.
    public static var toolsHelp: String {
        var lines: [String] = []
        for case let tool as [String: Any] in tools {
            let name = tool["name"] as? String ?? ""
            lines.append("\(name): \(tool["description"] as? String ?? "")")
            lines += argumentLines(tool["inputSchema"] as? [String: Any] ?? [:], indent: "  ")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// An object's properties, the required ones first, with what each takes.
    private static func argumentLines(_ schema: [String: Any], indent: String) -> [String] {
        let required = Set(schema["required"] as? [String] ?? [])
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let names = properties.keys.filter(required.contains).sorted() + properties.keys.filter { !required.contains($0) }.sorted()
        var lines: [String] = []
        for name in names {
            guard let property = properties[name] as? [String: Any] else { continue }
            let items = property["items"] as? [String: Any]
            var kind = property["type"] as? String ?? "value"
            if let choices = property["enum"] as? [String] { kind = choices.joined(separator: " | ") }
            if items != nil { kind = "a list of objects" }
            if required.contains(name) { kind += ", required" }
            let description = property["description"] as? String
            lines.append("\(indent)\(name) (\(kind))" + (description.map { ": \($0)" } ?? ""))
            if let items { lines += argumentLines(items, indent: indent + "  ") }
        }
        return lines
    }

    /// The skill that tells an AI agent how to run Bekitzur's tools from its terminal, with the command that does.
    /// - Parameter app: The agent's name, which it gives Bekitzur with each call.
    public static func skill(command: String, app: String) -> String {
        let run = "\"\(command)\" \(toolArgument)"
        let list = "\"\(command)\" \(toolsArgument)"
        return """
        ---
        name: bekitzur
        description: Reads and edits the user's recorded meetings and calls in Bekitzur, their Notes (summary, Decisions, Action Items, Open Questions) and Transcripts. Use when the user asks about a meeting, call, or Conversation, what someone said or committed to, their Action Items or decisions, or to change a Conversation's Notes.
        ---

        # Bekitzur

        Bekitzur records the user's conversations on this Mac and writes Notes for each. Run its tools from the terminal, the arguments a JSON object:

        ```bash
        \(run) find_conversations '{"person": "Dana", "after": "2026-11-02"}' --as "\(app)"
        ```

        `\(list)` lists the tools and their arguments.

        1. Find Conversations with `find_conversations` (words, a person, days), or the names `person` takes with `list_people`.
        2. Read one with `get_conversation` (its Notes, their item names like A2, and their version) and `get_transcript`, a stretch of minutes at a time for a long one.
        3. Answer from those, quoting the Transcript as it is: Conversations are often in Hebrew with English terms.

        Change Notes only when the user asks: call `get_conversation` again, then `edit_notes` with its `notes_version` and the items as it named them. Give arguments that hold an apostrophe on stdin, with `-` in their place:

        ```bash
        \(run) edit_notes - --as "\(app)" <<'EOF'
        {"conversation": "…", "notes_version": "…", "edits": [{"action": "add", "section": "action_item", "text": "…", "owner": "Dana's team"}]}
        EOF
        ```

        The user sees each change in Bekitzur, and can undo it. If a tool says AI apps aren't allowed, ask the user to turn on Settings → AI apps → Let AI apps use your Conversations in Bekitzur.
        """
    }

    /// Runs one tool from the terminal: `--tool <name> ['<arguments as JSON>' | -] [--as <agent>]`.
    public static let toolArgument = "--tool"
    /// Lists the tools and their arguments.
    public static let toolsArgument = "--tools"

    func run(_ tool: Tool, with arguments: [String: Any]) throws -> String {
        switch tool {
        case .findConversations: try find(arguments)
        case .listPeople: people()
        case .getConversation: try conversation(arguments)
        case .getTranscript: try transcript(arguments)
        case .editNotes: try edit(arguments)
        }
    }

    /// The Conversations with Notes, newest first.
    private var ready: [ConversationInfo] {
        store.all().filter { $0.status == .unreviewed || $0.status == .reviewed }
    }

    private func find(_ arguments: [String: Any]) throws -> String {
        let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let person = (arguments["person"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let after = try Self.day(arguments["after"], named: "after")
        let before = try Self.day(arguments["before"], named: "before").flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
        let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 100)
        let filter = ConversationFilter(query: text)
        var found: [String] = []
        for info in ready where found.count < limit {
            if let after, info.startedAt < after { continue }
            if let before, info.startedAt >= before { continue }
            guard let result = store.result(for: info.id) else { continue }
            let entry = SearchEntry(result, user: user())
            if !person.isEmpty, !entry.people.contains(where: { Self.same($0, person) }) { continue }
            let title = info.title ?? result.notes.title
            guard filter.matches(title: title, entry: entry) else { continue }
            var line = "- \(info.id): \(Self.summary(of: info, result, people: entry.people))"
            if let excerpt = filter.excerpt(title: title, entry: entry) {
                line += "\n  Found in: “\(excerpt.before)\(excerpt.match)\(excerpt.after)”"
            }
            found.append(line)
        }
        return found.isEmpty ? "No Conversation fits that." : found.joined(separator: "\n")
    }

    private func people() -> String {
        var entries: [SearchEntry] = []
        var last: [String: Date] = [:]
        for info in ready {
            guard let result = store.result(for: info.id) else { continue }
            let entry = SearchEntry(result, user: user())
            entries.append(entry)
            for name in entry.people where last[name] == nil { last[name] = info.startedAt }
        }
        let people = ConversationFilter.people(in: entries)
        guard !people.isEmpty else { return "The user hasn't named anyone in their Conversations yet." }
        return people.map { person in
            let count = person.conversations == 1 ? "1 Conversation" : "\(person.conversations) Conversations"
            return "- \(person.name): \(count), the last on \(Self.day(last[person.name] ?? .distantPast, time: false))"
        }.joined(separator: "\n")
    }

    private func conversation(_ arguments: [String: Any]) throws -> String {
        let (info, result) = try withNotes(arguments)
        var lines = ["# \(info.title ?? result.notes.title)", "ID: \(info.id)", "When: " + Self.when(info, result)]
        let speakers = result.speakers.sorted { $0.speechSeconds > $1.speechSeconds }
        if !speakers.isEmpty {
            lines.append("Speakers: " + speakers.map { "\($0.displayName) (\(Self.minutes($0.speechSeconds)))" }.joined(separator: ", "))
        }
        lines.append("Notes language: \((result.notes.language ?? .english).name)")
        lines.append("Notes version, for edit_notes: \(Self.version(of: result.notes))")
        lines.append("")
        lines.append(Self.listing(result.notes, turns: result.turns))
        return lines.joined(separator: "\n")
    }

    private func transcript(_ arguments: [String: Any]) throws -> String {
        let (info, result) = try withNotes(arguments)
        let turns = NotesWriter.turns(from: result.transcript.applying(store.flags(for: info.id)))
        let from = (arguments["from_minute"] as? Double ?? 0) * 60
        let to = (arguments["to_minute"] as? Double).map { $0 * 60 } ?? .infinity
        let shown = turns.filter { turn in
            let start = turn.start ?? 0
            return start >= from && start < to
        }
        var lines = ["# \(info.title ?? result.notes.title)", "When: " + Self.when(info, result), ""]
        if shown.isEmpty { lines.append("Nothing was said then.") }
        for turn in shown { lines.append("[\(turn.id) \(timestamp(turn.start ?? 0))] \(turn.speaker): \(turn.text)") }
        return lines.joined(separator: "\n")
    }

    private func edit(_ arguments: [String: Any]) throws -> String {
        let (info, result) = try withNotes(arguments)
        guard let version = arguments["notes_version"] as? String, version == Self.version(of: result.notes) else {
            throw ToolFailure("The Notes changed since you read them: get the Conversation again, and name the items as it lists them now.")
        }
        let edits = try Self.edits(from: arguments["edits"])
        let today = now()
        let (changed, applied) = result.notes.applying(edits) { phrase in Self.due(phrase, today: today) }
        guard !applied.isEmpty else { throw ToolFailure("Nothing changed: the edits named items these Notes don't have, or left them as they were.") }
        var saved = result
        saved.notes = changed
        saved.notesEdited = true
        try store.save(saved, for: info.id)
        if changed.title != result.notes.title {
            var renamed = info
            renamed.title = changed.title
            renamed.renamed = true
            try store.save(renamed)
        }
        var exchange = ChatExchange(message: (arguments["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        exchange.from = client ?? ""
        exchange.edits = applied
        exchange.notesBefore = result.notes
        exchange.notesAfter = changed
        try store.save(store.chat(for: info.id) + [exchange], for: info.id)
        didChange(info.id)
        return "Changed the Notes of “\(changed.title)”:\n" + applied.map { "- " + Self.describe($0) }.joined(separator: "\n")
            + "\nThe user sees these changes in the Conversation's Chat tab in Bekitzur, where they can undo them. "
            + "The Notes' version is now \(Self.version(of: changed))."
    }

    /// The Conversation the arguments name, which has Notes.
    private func withNotes(_ arguments: [String: Any]) throws -> (ConversationInfo, ProcessedConversation) {
        guard let id = arguments["conversation"] as? String, !id.isEmpty else {
            throw ToolFailure("Give the Conversation's ID, from find_conversations.")
        }
        guard let info = store.all().first(where: { $0.id == id }) else {
            throw ToolFailure("No Conversation has the ID \(id); find_conversations gives their IDs.")
        }
        guard info.status == .unreviewed || info.status == .reviewed, let result = store.result(for: id) else {
            throw ToolFailure("“\(info.title ?? id)” has no Notes yet: it's still being recorded or processed, or processing failed.")
        }
        return (info, result)
    }

    /// The Notes, each item named by its place, as edit_notes names them, with the turns it comes from.
    static func listing(_ notes: Notes, turns: [Turn]) -> String {
        var starts: [String: Double] = [:]
        for turn in turns where starts[turn.id] == nil { starts[turn.id] = turn.start }
        func sources(_ ids: [String]) -> String {
            guard !ids.isEmpty else { return "" }
            return " [from " + ids.map { id in starts[id].map { "\(id) at \(timestamp($0))" } ?? id }.joined(separator: ", ") + "]"
        }
        var lines = ["Title: \(notes.title)", "Summary: \(notes.summary)", ""]
        lines.append(notes.decisions.isEmpty ? "Decisions: none" : "Decisions:")
        for (index, decision) in notes.decisions.enumerated() { lines.append("D\(index + 1). \(decision.text)" + sources(decision.sourceTurns)) }
        lines.append(notes.actionItems.isEmpty ? "Action items: none" : "Action items:")
        for (index, item) in notes.actionItems.enumerated() {
            var details: [String] = []
            if let owner = item.owner { details.append("owner: \(owner)") }
            if let due = due(of: item) { details.append("due: \(due)") }
            if item.done == true { details.append("done") }
            let shown = details.isEmpty ? "" : " (" + details.joined(separator: "; ") + ")"
            lines.append("A\(index + 1). \(item.text)" + shown + sources(item.sourceTurns))
        }
        lines.append(notes.openQuestions.isEmpty ? "Open questions: none" : "Open questions:")
        for (index, question) in notes.openQuestions.enumerated() { lines.append("Q\(index + 1). \(question.text)" + sources(question.sourceTurns)) }
        return lines.joined(separator: "\n")
    }

    /// An Action Item's due day and time, and the words it was said in.
    private static func due(of item: ActionItem) -> String? {
        guard let date = item.dueDate else { return item.duePhrase.map { "“\($0)”" } }
        var due = day(dayFormatter().date(from: date) ?? .distantPast, time: false)
        if let time = item.dueTime { due += " at \(time)" }
        if let phrase = item.duePhrase, phrase != date, !phrase.hasPrefix(date) { due += ", said as “\(phrase)”" }
        return due
    }

    /// The edits as the Notes take them, with items named as get_conversation names them.
    static func edits(from value: Any?) throws -> [NotesEdit] {
        guard let list = value as? [[String: Any]], !list.isEmpty else { throw ToolFailure("Give the edits: a list, each with an action.") }
        return try list.map { edit -> NotesEdit in
            let text = edit["text"] as? String
            let item = (edit["item"] as? String ?? "").uppercased()
            let owner = edit["owner"] as? String
            let due = edit["due"] as? String
            switch edit["action"] as? String {
            case "add":
                guard let section = (edit["section"] as? String).flatMap(NotesEdit.Section.init(rawValue:)) else {
                    throw ToolFailure("An edit that adds needs a section: decision, action_item, or open_question.")
                }
                return .add(section, text: text ?? "", owner: owner, due: due)
            case "change":
                return .change(item: item, text: text, owner: owner, due: due, done: edit["done"] as? Bool)
            case "remove":
                return .remove(item: item)
            case "title":
                return .title(text ?? "")
            case "summary":
                return .summary(text ?? "")
            default:
                throw ToolFailure("Each edit's action is add, change, remove, title, or summary.")
            }
        }
    }

    /// A day like 2026-11-20, with a time like 16:00 or not, as it is; words like "next Thursday", from today.
    static func due(_ phrase: String, today: Date) -> (date: String, time: String?)? {
        let said = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = said.wholeMatch(of: /(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}):(\d{2}))?/), dayFormatter().date(from: String(match.1)) != nil {
            var time: String?
            if let hour = match.2.flatMap({ Int($0) }), let minute = match.3 { time = String(format: "%02d:", hour) + minute }
            return (String(match.1), time)
        }
        return DueDateResolver.due(said, from: today)
    }

    /// The Notes as they are now, in a few letters: edit_notes takes it to tell the Notes haven't changed since.
    static func version(of notes: Notes) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: (try? encoder.encode(notes)) ?? Data())
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ edit: AppliedEdit) -> String {
        let section = switch edit.section {
        case .decision: "Decision"
        case .actionItem: "Action Item"
        case .openQuestion: "Open Question"
        case nil: "item"
        }
        return switch edit.kind {
        case .title: "New title: \(edit.text)"
        case .summary: "New summary: \(edit.text)"
        case .added, .changed, .removed: "\(edit.kind.rawValue.capitalized) \(section): \(edit.text)"
        }
    }

    /// When, how long, in which language, who was there, and how many Action Items are still open.
    private static func summary(of info: ConversationInfo, _ result: ProcessedConversation, people: Set<String>) -> String {
        var parts = ["“\(info.title ?? result.notes.title)”", when(info, result)]
        if !people.isEmpty { parts.append("with " + people.sorted().joined(separator: ", ")) }
        let count = result.notes.actionItems.count
        let open = result.notes.actionItems.filter { $0.done != true }.count
        parts.append(count == 1 ? "1 Action Item, \(open) open" : "\(count) Action Items, \(open) open")
        return parts.joined(separator: "; ")
    }

    private static func when(_ info: ConversationInfo, _ result: ProcessedConversation) -> String {
        var when = day(info.startedAt, time: true) + ", " + minutes(result.transcript.segments.last?.end ?? 0)
        if let language = info.language { when += ", in \(language.name)" }
        return when
    }

    static func day(_ date: Date, time: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = time ? "EEEE, d MMMM yyyy, HH:mm" : "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    private static func minutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "under a minute" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static func day(_ value: Any?, named name: String) throws -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        guard let date = dayFormatter().date(from: text) else { throw ToolFailure("\(name) is a day like 2026-11-02.") }
        return date
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func same(_ name: String, _ other: String) -> Bool {
        name.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static let toolsJSON = #"""
    [
      {
        "name": "find_conversations",
        "title": "Find Conversations",
        "description": "Finds the user's recorded Conversations, newest first, by words in their titles, Notes, or Transcripts, by someone who was there, and by date. Each comes with its ID for the other tools, when it was, how long, its language, who was there, and how many of its Action Items are still open, with the line the words were found in.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {"type": "string", "description": "Words to look for. Case and Hebrew vowel marks don't matter; Conversations are often in Hebrew, with English terms."},
            "person": {"type": "string", "description": "Someone who was there, by a name list_people gives."},
            "after": {"type": "string", "description": "Only Conversations on this day or later, like 2026-11-02."},
            "before": {"type": "string", "description": "Only Conversations on this day or earlier, like 2026-11-09."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "At most this many; 20 if not given."}
          },
          "additionalProperties": false
        },
        "annotations": {"readOnlyHint": true, "openWorldHint": false}
      },
      {
        "name": "list_people",
        "title": "List people",
        "description": "Lists the people the user has named in their Conversations, with how many Conversations each was in and the day of the last one. The user isn't listed.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
        "annotations": {"readOnlyHint": true, "openWorldHint": false}
      },
      {
        "name": "get_conversation",
        "title": "Get a Conversation",
        "description": "Gets a Conversation: when it was, how long, who spoke and how much, and its Notes: the summary, Decisions, Action Items with their Owners, due dates, and whether they're done, and Open Questions. Each item is named as edit_notes names it (D1, A1, Q1), with the turns of the Transcript it comes from. It also gives the Notes' language and version, which edit_notes needs.",
        "inputSchema": {
          "type": "object",
          "properties": {"conversation": {"type": "string", "description": "The Conversation's ID, from find_conversations."}},
          "required": ["conversation"],
          "additionalProperties": false
        },
        "annotations": {"readOnlyHint": true, "openWorldHint": false}
      },
      {
        "name": "get_transcript",
        "title": "Get a Transcript",
        "description": "Gets what was said in a Conversation, with the user's corrections: numbered turns, each with when it started, who spoke, and what they said. A Transcript runs about 1,000 characters a minute, so for a long Conversation, get a stretch of it by minutes.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "conversation": {"type": "string", "description": "The Conversation's ID, from find_conversations."},
            "from_minute": {"type": "number", "minimum": 0, "description": "Only turns that start at this minute or later."},
            "to_minute": {"type": "number", "minimum": 0, "description": "Only turns that start before this minute."}
          },
          "required": ["conversation"],
          "additionalProperties": false
        },
        "annotations": {"readOnlyHint": true, "openWorldHint": false}
      },
      {
        "name": "edit_notes",
        "title": "Edit a Conversation's Notes",
        "description": "Changes a Conversation's Notes: adds, changes, or removes Decisions, Action Items, and Open Questions, checks Action Items off, or gives the Notes a new title or summary. Name items as get_conversation last listed them, and give the Notes' version it gave: if the Notes changed since, nothing changes and you're asked to read them again. Write in the Notes' language. The user sees the changes in Bekitzur and can undo them. Change the Notes only when the user asks.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "conversation": {"type": "string", "description": "The Conversation's ID, from find_conversations."},
            "notes_version": {"type": "string", "description": "The Notes' version that get_conversation gave."},
            "edits": {
              "type": "array",
              "minItems": 1,
              "items": {
                "type": "object",
                "properties": {
                  "action": {"type": "string", "enum": ["add", "change", "remove", "title", "summary"]},
                  "section": {"type": "string", "enum": ["decision", "action_item", "open_question"], "description": "Where an added item goes."},
                  "item": {"type": "string", "description": "The item a change or removal is for, like A2."},
                  "text": {"type": "string", "description": "An item's text, or the new title or summary."},
                  "owner": {"type": "string", "description": "An Action Item's Owner; an empty string takes it off."},
                  "due": {"type": "string", "description": "When an Action Item is due: a day like 2026-11-20, with a time like 16:00 or not, or words like \"next Thursday\", which count from today; an empty string takes it off."},
                  "done": {"type": "boolean", "description": "Whether an Action Item is done."}
                },
                "required": ["action"],
                "additionalProperties": false
              }
            },
            "reason": {"type": "string", "description": "A few words on why, which the user sees with the changes, in the user's language."}
          },
          "required": ["conversation", "notes_version", "edits"],
          "additionalProperties": false
        },
        "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false}
      }
    ]
    """#
}
