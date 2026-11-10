import Foundation

/// One speaker turn of a Transcript as the Notes see it, numbered so Sources can point at it.
public struct Turn: Codable, Sendable, Equatable {
    /// "T001", "T002", …
    public var id: String
    public var speaker: String
    public var text: String
    public var start: Double?
    public var end: Double?

    public init(id: String, speaker: String, text: String, start: Double? = nil, end: Double? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Decision: Codable, Sendable, Equatable {
    public var text: String
    /// The Source: turn IDs where the Decision was reached.
    public var sourceTurns: [String]
    public var quote: String

    /// Without a Source, for one the user adds.
    public init(text: String, sourceTurns: [String] = [], quote: String = "") {
        self.text = text
        self.sourceTurns = sourceTurns
        self.quote = quote
    }
}

public struct ActionItem: Codable, Sendable, Equatable {
    public var text: String
    public var owner: String?
    /// When it's due, in the words that were spoken.
    public var duePhrase: String?
    /// The due date resolved from the phrase against the Conversation's date, as YYYY-MM-DD.
    public var dueDate: String?
    public var sourceTurns: [String]
    public var quote: String
    /// The user checked it off.
    public var done: Bool?

    public init(text: String, owner: String? = nil, duePhrase: String? = nil, dueDate: String? = nil, sourceTurns: [String] = [], quote: String = "", done: Bool? = nil) {
        self.text = text
        self.owner = owner
        self.duePhrase = duePhrase
        self.dueDate = dueDate
        self.sourceTurns = sourceTurns
        self.quote = quote
        self.done = done
    }

    /// An Owner or due phrase of "null", or blank, is none, from the model and from saved Notes alike: the model can
    /// write null as text, which would show as a due date of "null".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        owner = Self.given(try container.decodeIfPresent(String.self, forKey: .owner))
        duePhrase = Self.given(try container.decodeIfPresent(String.self, forKey: .duePhrase))
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        sourceTurns = try container.decode([String].self, forKey: .sourceTurns)
        quote = try container.decode(String.self, forKey: .quote)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
    }

    private static func given(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : text
    }
}

public struct OpenQuestion: Codable, Sendable, Equatable {
    public var text: String
    public var sourceTurns: [String]

    public init(text: String, sourceTurns: [String] = []) {
        self.text = text
        self.sourceTurns = sourceTurns
    }
}

public struct Notes: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    /// The language they're written in; nil for Notes from before they could be in Hebrew, which are in English.
    public var language: ConversationLanguage?

    /// Notes not written yet.
    public init() {
        self.init(title: "", summary: "", decisions: [], actionItems: [], openQuestions: [])
    }

    init(title: String, summary: String, decisions: [Decision], actionItems: [ActionItem], openQuestions: [OpenQuestion]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    /// There are Action Items, and every one is checked off.
    public var actionItemsDone: Bool {
        !actionItems.isEmpty && actionItems.allSatisfy { $0.done == true }
    }
}
