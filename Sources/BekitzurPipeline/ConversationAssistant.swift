import BekitzurDomain
import BekitzurNotes
import Foundation

/// Chats about Conversations, one Conversation at a time. The language model and the last Conversation's transcript
/// stay loaded for follow-up messages until nobody has sent anything for a while.
public actor ConversationAssistant {
    private var chat: ConversationChat?
    private var conversation: String?
    private var lastUse = Date.distantPast

    public init() {}

    /// - Parameters:
    ///   - transcript: The Transcript with the user's fixes; when it changes, the chat starts over.
    ///   - notes: The Notes as they are now, which the reply can change.
    ///   - earlier: The messages already sent about this Conversation, with the changes and answers the user was shown,
    ///     for a chat that starts over.
    ///   - attached: Another Conversation the user picked to bring in with the message.
    ///   - others: The other Conversations a message can name, for the chat to find the one it means.
    public func send(
        _ message: String,
        about id: String,
        transcript: Transcript,
        notes: Notes,
        date: Date,
        language: ConversationLanguage,
        after earlier: [ChatExchange] = [],
        bringing attached: ChatReference? = nil,
        from others: OtherConversations? = nil
    ) throws -> ChatReply {
        defer { lastUse = Date() }
        let turns = NotesWriter.turns(from: transcript)
        if conversation != id || chat?.turns != turns {
            chat = nil
            chat = ConversationChat(model: try LanguageModel(modelURL: BekitzurPaths.languageModel), turns: turns, date: date, language: language)
            conversation = id
        }
        return try chat!.send(message, notes: notes, after: earlier, bringing: attached, from: others)
    }

    /// The language model's last reply, before its quotes were checked.
    public var lastReply: String { chat?.lastReply ?? "" }

    /// Frees the model's memory if nobody has sent anything for `seconds`.
    public func unload(ifIdleFor seconds: TimeInterval) {
        guard Date().timeIntervalSince(lastUse) >= seconds else { return }
        chat = nil
        conversation = nil
    }
}
