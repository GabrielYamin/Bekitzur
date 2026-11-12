import AppKit
import BekitzurLibrary
import BekitzurPipeline

/// AI apps like Claude and Cursor, which use the Conversations through Bekitzur's MCP server once the user lets them.
enum AIApps {
    /// The server the app runs with `--mcp`, over its Conversations and settings.
    static func server() -> MCPServer {
        MCPServer(
            store: ConversationLibrary(root: BekitzurPaths.conversations),
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            user: { UserDefaults.standard.string(forKey: "userName") ?? NSFullUserName() },
            allowed: { UserDefaults.standard.bool(forKey: MCPServer.allowedKey) },
            didChange: { id in
                DistributedNotificationCenter.default().postNotificationName(MCPServer.changed, object: id, userInfo: nil, deliverImmediately: true)
            },
            log: { AppLog.write($0) }
        )
    }

    /// The command that starts Bekitzur's MCP server: this app, with `--mcp`.
    static var command: String {
        Bundle.main.executableURL?.path ?? "/Applications/Bekitzur.app/Contents/MacOS/Bekitzur"
    }

    /// The entry an AI app's MCP settings take to start Bekitzur's server, as Cursor and Claude read them.
    static var setup: String {
        let entry: [String: Any] = ["mcpServers": ["bekitzur": ["command": command, "args": [MCPServer.argument]]]]
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
