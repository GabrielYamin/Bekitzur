import BekitzurDomain
import Foundation

/// Conversations on disk: one folder each, with the Recording's tracks, info.json, and result.json.
public struct ConversationLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder(for id: String) -> URL {
        root.appending(path: id)
    }

    public func all() -> [ConversationInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Self.decoder.decode(ConversationInfo.self, from: Data(contentsOf: $0.appending(path: "info.json"))) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func create(language: ConversationLanguage? = nil, startedAt: Date = Date()) throws -> ConversationInfo {
        let info = ConversationInfo(id: freeID(from: Self.id(for: startedAt)), startedAt: startedAt, language: language, status: .recording)
        try FileManager.default.createDirectory(at: folder(for: info.id), withIntermediateDirectories: true)
        try save(info)
        return info
    }

    public func save(_ info: ConversationInfo) throws {
        try write(info, to: folder(for: info.id).appending(path: "info.json"))
    }

    /// A folder name from when a Conversation started: "2026-10-19-143012".
    static func id(for startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: startedAt)
    }

    /// `base`, or with "-2", "-3", … when a Conversation already has it.
    func freeID(from base: String) -> String {
        var id = base
        var copy = 1
        while FileManager.default.fileExists(atPath: folder(for: id).path) {
            copy += 1
            id = "\(base)-\(copy)"
        }
        return id
    }

    public func result(for id: String) -> ProcessedConversation? {
        try? Self.decoder.decode(ProcessedConversation.self, from: Data(contentsOf: folder(for: id).appending(path: "result.json")))
    }

    public func save(_ result: ProcessedConversation, for id: String) throws {
        try write(result, to: folder(for: id).appending(path: "result.json"))
    }

    public func flags(for id: String) -> TranscriptFlags {
        (try? Self.decoder.decode(TranscriptFlags.self, from: Data(contentsOf: folder(for: id).appending(path: "flags.json")))) ?? TranscriptFlags()
    }

    public func save(_ flags: TranscriptFlags, for id: String) throws {
        try write(flags, to: folder(for: id).appending(path: "flags.json"))
    }

    /// For a new Transcript, whose words the old flags no longer point to.
    public func deleteFlags(for id: String) {
        try? FileManager.default.removeItem(at: folder(for: id).appending(path: "flags.json"))
    }

    public func liveTranscript(for id: String) -> LiveTranscript? {
        try? Self.decoder.decode(LiveTranscript.self, from: Data(contentsOf: folder(for: id).appending(path: "live.json")))
    }

    public func save(_ live: LiveTranscript, for id: String) throws {
        try write(live, to: folder(for: id).appending(path: "live.json"))
    }

    /// Once the live Transcript is in result.json, or when the Recording is transcribed again.
    public func deleteLiveTranscript(for id: String) {
        try? FileManager.default.removeItem(at: folder(for: id).appending(path: "live.json"))
    }

    /// The Conversation's chat, oldest message first.
    public func chat(for id: String) -> [ChatExchange] {
        (try? Self.decoder.decode([ChatExchange].self, from: Data(contentsOf: folder(for: id).appending(path: Self.chatFile)))) ?? []
    }

    public func save(_ chat: [ChatExchange], for id: String) throws {
        try write(chat, to: folder(for: id).appending(path: Self.chatFile))
    }

    /// The user's own, so an exported Conversation leaves it out.
    static let chatFile = "chat.json"

    /// The Recording's audio: the two recorded tracks, or an imported recording.
    public func audioTracks(for id: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension != "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension ConversationLibrary: ConversationStore {}
