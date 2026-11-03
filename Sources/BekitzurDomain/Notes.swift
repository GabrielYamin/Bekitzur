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

    public init(text: String, owner: String? = nil, duePhrase: String? = nil, dueDate: String? = nil, sourceTurns: [String] = [], quote: String = "") {
        self.text = text
        self.owner = owner
        self.duePhrase = duePhrase
        self.dueDate = dueDate
        self.sourceTurns = sourceTurns
        self.quote = quote
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
}
