import Foundation

/// The saved Conversations, which Bekitzur's MCP server reads and changes for AI apps as the app does.
public protocol ConversationStore: Sendable {
    /// Newest first.
    func all() -> [ConversationInfo]
    func result(for id: String) -> ProcessedConversation?
    func flags(for id: String) -> TranscriptFlags
    /// Oldest message first.
    func chat(for id: String) -> [ChatExchange]
    func save(_ info: ConversationInfo) throws
    func save(_ result: ProcessedConversation, for id: String) throws
    func save(_ chat: [ChatExchange], for id: String) throws
}
