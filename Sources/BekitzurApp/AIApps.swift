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

    /// Runs one tool for an AI agent that calls Bekitzur from its terminal, prints what it gives, and returns 1 when it
    /// failed: `--tool <name> ['<arguments as JSON>' | -] [--as <agent>]`, `-` reading the arguments from stdin.
    static func runTool(_ arguments: [String]) -> Int32 {
        var given = arguments
        var agent: String?
        if let index = given.firstIndex(of: "--as"), index + 1 < given.count {
            agent = given[index + 1]
            given.removeSubrange(index...(index + 1))
        }
        guard let name = given.first else {
            print("Bekitzur \(MCPServer.toolArgument) <name> ['<arguments as JSON>' | -] [--as <agent>]; \(MCPServer.toolsArgument) lists the tools.")
            return 2
        }
        var json = given.count > 1 ? given[1] : "{}"
        if json == "-" { json = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            print(#"The arguments are a JSON object, like '{"text": "Aurora"}'."#)
            return 2
        }
        let (text, failed) = server().call(name, arguments: object, by: agent)
        print(text)
        return failed ? 1 : 0
    }

    /// AI agents that keep skills in a folder of their own, which Settings adds Bekitzur's to.
    enum Agent: String, CaseIterable {
        case cursor = "Cursor"
        case claudeCode = "Claude Code"

        var skills: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return switch self {
            case .cursor: home.appending(path: ".cursor/skills")
            case .claudeCode: home.appending(path: ".claude/skills")
            }
        }
    }

    /// Writes the skill that tells the agent how to run Bekitzur's tools from its terminal, over one written before.
    static func addSkill(for agent: Agent) throws {
        let folder = agent.skills.appending(path: "bekitzur")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MCPServer.skill(command: command, app: agent.rawValue).write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// `--add-skill <cursor | claude-code>`: adds the skill from the terminal, as Settings does.
    static let addSkillArgument = "--add-skill"

    static func addSkill(_ arguments: [String]) -> Int32 {
        let agents: [String: Agent] = ["cursor": .cursor, "claude-code": .claudeCode]
        guard let agent = arguments.first.flatMap({ agents[$0] }) else {
            print("Bekitzur \(addSkillArgument) <cursor | claude-code>")
            return 2
        }
        do {
            try addSkill(for: agent)
            print("Added Bekitzur's skill to \(agent.rawValue), in \(agent.skills.appending(path: "bekitzur").path).")
            return 0
        } catch {
            print("Couldn't add the skill: \(error.localizedDescription)")
            return 1
        }
    }
}
