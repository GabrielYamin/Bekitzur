import BekitzurDomain
import Foundation

/// Bekitzur's MCP server, which lets AI apps like Claude and Cursor find the user's Conversations, read their Notes and
/// Transcripts, and change their Notes. The app runs it with `--mcp`: the AI app starts it, writes JSON-RPC messages to
/// its stdin, a line each, and reads its replies from stdout. It speaks the current protocol, whose requests each carry
/// their version, and the earlier ones, which start with `initialize`. Its tools do nothing until the user lets AI apps
/// use their Conversations in Settings.
public final class MCPServer {
    public static let argument = "--mcp"
    /// The Settings switch, off until the user turns it on.
    public static let allowedKey = "aiAppsAllowed"
    /// Posted with a Conversation's ID after the server changes it, so the open app reads it again.
    public static let changed = Notification.Name("app.bekitzur.mac.conversationChanged")

    static let protocolVersion = "2026-07-28"
    /// The versions that start with `initialize`, newest first.
    static let initializeVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let store: any ConversationStore
    let version: String
    /// The user's own name, which the people in their Conversations leave out.
    let user: () -> String
    let allowed: () -> Bool
    let didChange: (String) -> Void
    let now: () -> Date
    let log: (String) -> Void
    /// The AI app on the other end, as it names itself; nil until it does.
    var client: String?

    public init(
        store: any ConversationStore,
        version: String,
        user: @escaping () -> String,
        allowed: @escaping () -> Bool,
        didChange: @escaping (String) -> Void,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.version = version
        self.user = user
        self.allowed = allowed
        self.didChange = didChange
        self.now = now
        self.log = log
    }

    /// Answers the AI app until it closes stdin, and returns the exit status.
    public func serve() -> Int32 {
        while let line = readLine() {
            guard let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
        return 0
    }

    /// The reply to one message; nil for a notification, which gets none.
    public func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.reply(NSNull(), error: -32700, "Parse error")
        }
        // A notification, or a reply to a request this server never sends.
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]
        if let info = (meta["io.modelcontextprotocol/clientInfo"] ?? params["clientInfo"]) as? [String: Any] {
            client = Self.name(of: info) ?? client
        }
        if let asked = meta["io.modelcontextprotocol/protocolVersion"] as? String, asked != Self.protocolVersion, method != "server/discover" {
            return Self.reply(id, error: -32022, "Unsupported protocol version", data: ["supported": Self.supported, "requested": asked])
        }
        switch method {
        case "server/discover":
            return reply(id, [
                "supportedVersions": Self.supported, "capabilities": Self.capabilities, "instructions": Self.instructions,
                "ttlMs": 0, "cacheScope": "private",
            ])
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return reply(id, [
                "protocolVersion": Self.initializeVersions.contains(asked) ? asked : Self.initializeVersions[0],
                "capabilities": Self.capabilities, "serverInfo": serverInfo, "instructions": Self.instructions,
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools, "ttlMs": 0, "cacheScope": "private"])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else {
                return Self.reply(id, error: -32602, "Unknown tool: \(params["name"] as? String ?? "none")")
            }
            let (text, failed) = call(tool, with: params["arguments"] as? [String: Any] ?? [:])
            return reply(id, ["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return Self.reply(id, error: -32601, "Method not found: \(method)")
        }
    }

    static var supported: [String] { [protocolVersion] + initializeVersions }

    static var capabilities: [String: Any] { ["tools": ["listChanged": false]] }

    private var serverInfo: [String: Any] { ["name": "bekitzur", "title": "Bekitzur", "version": version] }

    /// Runs a tool by name for an AI agent that calls Bekitzur from its terminal, where MCP servers aren't allowed.
    /// - Parameter app: The agent, as it names itself, for the log and for its changes in the Conversation's chat.
    public func call(_ name: String, arguments: [String: Any], by app: String?) -> (text: String, failed: Bool) {
        client = app ?? client
        guard let tool = Tool(rawValue: name) else {
            return ("No tool is called \(name). The tools are " + Tool.allCases.map(\.rawValue).joined(separator: ", ") + ".", true)
        }
        return call(tool, with: arguments)
    }

    /// A tool's text, and whether it failed, which the model sees to do better, as the protocol asks of a tool's errors.
    private func call(_ tool: Tool, with arguments: [String: Any]) -> (text: String, failed: Bool) {
        guard allowed() else { return (Self.notAllowed, true) }
        let conversation = arguments["conversation"] as? String
        log("AI apps: \(client ?? "an AI app") used \(tool.rawValue)" + (conversation.map { " on \($0)" } ?? ""))
        do {
            return (try run(tool, with: arguments), false)
        } catch let failure as ToolFailure {
            return (failure.message, true)
        } catch {
            return ("Bekitzur couldn't do that: \(error.localizedDescription)", true)
        }
    }

    /// The AI app's name to show the user: its title, or a known app's name for its ID.
    static func name(of client: [String: Any]) -> String? {
        if let title = client["title"] as? String, !title.isEmpty { return title }
        guard let name = client["name"] as? String, !name.isEmpty else { return nil }
        let id = name.lowercased()
        if id.hasPrefix("claude-code") { return "Claude Code" }
        if id.hasPrefix("claude") { return "Claude" }
        if id.contains("cursor") { return "Cursor" }
        if id.contains("codex") { return "Codex" }
        if id.contains("gemini") { return "Gemini" }
        return name
    }

    /// A result, marked complete and signed with the server's name, as the current protocol has every result.
    private func reply(_ id: Any, _ result: [String: Any]) -> String {
        var result = result
        result["resultType"] = "complete"
        result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func reply(_ id: Any, error code: Int, _ message: String, data: [String: Any]? = nil) -> String {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": error])
    }

    /// One line of JSON: a message can't hold a line break.
    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
