import Foundation

/// What a Conversation's transcript says in answer to a question, or nothing when it doesn't say.
public struct Answer: Codable, Sendable, Equatable {
    /// Nil when the transcript doesn't answer the question; then there's no evidence either.
    public let text: String?
    /// The turns the answer comes from, each with a quote checked against the turn's text.
    public let evidence: [Evidence]

    public static let notInConversation = Answer(text: nil, evidence: [])

    public init(text: String?, evidence: [Evidence]) {
        self.text = text
        self.evidence = evidence
    }
}

/// A quote from one turn of a transcript, like "T012", with who said it and when, once checked.
public struct Evidence: Codable, Sendable, Equatable {
    public let turn: String
    public let quote: String
    public var speaker: String?
    public var start: Double?

    public init(turn: String, quote: String, speaker: String? = nil, start: Double? = nil) {
        self.turn = turn
        self.quote = quote
        self.speaker = speaker
        self.start = start
    }
}
