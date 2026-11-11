import Foundation

/// A chat about one Conversation, over its Transcript and its Notes.
public enum Chat {
    /// The longest Conversation it takes: past about two hours of Transcript, the model stops finding what a message
    /// asks about.
    public static let longestConversation: TimeInterval = 2 * 60 * 60
}

/// One message to a Conversation's chat and its reply, kept with the Conversation.
public struct ChatExchange: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var message: String
    /// Nil while the chat replies, or when it couldn't.
    public var answer: Answer?
    public var failure: String?
    /// The changes it made to the Notes.
    public var edits: [AppliedEdit]
    /// The Notes before and after its changes, so Undo can put them back while nothing has changed them since.
    public var notesBefore: Notes?
    public var notesAfter: Notes?
    public var undone: Bool

    public init(message: String) {
        id = UUID()
        self.message = message
        edits = []
        undone = false
    }
}

/// The chat's reply to a message: its answer, and the Notes when it changed them.
public struct ChatReply: Sendable, Equatable {
    public let answer: Answer
    public let notes: Notes?
    public let edits: [AppliedEdit]

    public init(answer: Answer, notes: Notes? = nil, edits: [AppliedEdit] = []) {
        self.answer = answer
        self.notes = notes
        self.edits = edits
    }
}
