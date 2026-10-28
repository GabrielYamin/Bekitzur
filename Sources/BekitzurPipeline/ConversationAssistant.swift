import BekitzurDomain
import BekitzurNotes
import Foundation

/// Answers questions about Conversations, one Conversation at a time. The language model and the last Conversation's
/// transcript stay loaded for follow-up questions until nobody has asked anything for a while.
public actor ConversationAssistant {
    private var questions: ConversationQuestions?
    private var conversation: String?
    private var lastUse = Date.distantPast

    public init() {}

    /// - Parameters:
    ///   - transcript: The Transcript with the user's fixes; when it changes, the chat starts over.
    ///   - earlier: The questions already answered about this Conversation, with the answers the user was shown, for a
    ///     chat that starts over.
    public func ask(
        _ question: String,
        about id: String,
        transcript: Transcript,
        date: Date,
        language: ConversationLanguage,
        after earlier: [(question: String, answer: Answer)] = []
    ) throws -> Answer {
        defer { lastUse = Date() }
        let turns = NotesWriter.turns(from: transcript)
        if conversation != id || questions?.turns != turns {
            questions = nil
            questions = ConversationQuestions(model: try LanguageModel(modelURL: BekitzurPaths.languageModel), turns: turns, date: date, language: language)
            conversation = id
        }
        return try questions!.ask(question, after: earlier)
    }

    /// The language model's last reply, before its quotes were checked.
    public var lastReply: String { questions?.lastReply ?? "" }

    /// Frees the model's memory if nobody has asked anything for `seconds`.
    public func unload(ifIdleFor seconds: TimeInterval) {
        guard Date().timeIntervalSince(lastUse) >= seconds else { return }
        questions = nil
        conversation = nil
    }
}
