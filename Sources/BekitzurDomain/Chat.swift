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
    /// The model's reply as it wrote it, which a chat that starts over is given back as its own.
    public var reply: String?
    /// Another Conversation whose Notes the reply used, picked from the menu or found from the message's words.
    public var reference: ChatReference?

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
    /// The model's reply as it wrote it.
    public let raw: String
    /// The other Conversation whose Notes it used.
    public let reference: ChatReference?

    public init(answer: Answer, notes: Notes? = nil, edits: [AppliedEdit] = [], raw: String = "", reference: ChatReference? = nil) {
        self.answer = answer
        self.notes = notes
        self.edits = edits
        self.raw = raw
        self.reference = reference
    }
}

/// Another Conversation the chat can bring in, as a message can name it: by who was there and when.
public struct ChatCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let date: Date
    /// Its Speakers with a confirmed name.
    public let people: [String]

    public init(id: String, title: String, date: Date, people: [String]) {
        self.id = id
        self.title = title
        self.date = date
        self.people = people
    }
}

/// Another Conversation's Notes as the chat used them, kept with the reply so a chat that starts over has them.
public struct ChatReference: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let date: Date
    public let people: [String]
    public let notes: Notes

    public init(_ candidate: ChatCandidate, notes: Notes) {
        id = candidate.id
        title = candidate.title
        date = candidate.date
        people = candidate.people
        self.notes = notes
    }
}

/// The other Conversations a message can be about, and a way to read the Notes of the one it is.
public struct OtherConversations: Sendable {
    /// Newest first.
    public let candidates: [ChatCandidate]
    public let notes: @Sendable (String) -> Notes?

    public init(candidates: [ChatCandidate], notes: @escaping @Sendable (String) -> Notes?) {
        self.candidates = candidates
        self.notes = notes
    }
}

public enum ChatError: LocalizedError, Equatable {
    /// The message was about another Conversation, and none of them fit.
    case conversationNotFound

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound: String(localized: "None of your other Conversations fits that. You can pick it from the menu beside the message box.")
        }
    }
}
