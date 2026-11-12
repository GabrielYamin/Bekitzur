import Foundation
import Testing
@testable import BekitzurDomain
@testable import BekitzurLibrary
@testable import BekitzurPipeline

/// Bekitzur's MCP server as an AI app talks to it: a JSON-RPC message a line, and a reply a line.
struct MCPServerTests {
    /// Monday, 2 November 2026, at noon in UTC, which is the same day in Israel.
    private static let monday = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!

    private let notes: Notes = {
        var notes = Notes()
        notes.title = "Release sync"
        notes.summary = "The release moves to Thursday."
        notes.decisions = [Decision(text: "Release on Thursday", sourceTurns: ["T001"])]
        notes.actionItems = [ActionItem(text: "Update the runbook", owner: "Ron", sourceTurns: ["T002"])]
        notes.openQuestions = [OpenQuestion(text: "Who tells the customers?")]
        return notes
    }()

    /// What the server told the app it changed.
    private final class Changes {
        var ids: [String] = []
    }

    /// A reviewed Conversation of Dana's and Ron's with the user, in a library of its own.
    private func library() throws -> (ConversationLibrary, String) {
        let library = ConversationLibrary(root: FileManager.default.temporaryDirectory.appending(path: "bekitzur-mcp-\(UUID().uuidString)"))
        var info = try library.create(language: .hebrew, startedAt: Self.monday)
        info.status = .reviewed
        info.title = "Release sync"
        try library.save(info)
        let said = [("Dana", "נדחה את ה-release ליום חמישי.", 5.0), ("Ron", "אני אעדכן את ה-runbook.", 70.0)]
        let segments = said.map { TranscriptSegment(start: $0.2, end: $0.2 + 5, text: $0.1, speaker: $0.0) }
        let turns = said.enumerated().map { Turn(id: "T00\($0.offset + 1)", speaker: $0.element.0, text: $0.element.1, start: $0.element.2, end: $0.element.2 + 5) }
        let speakers = [("Dana", 300.0), ("Ron", 120.0), ("Gabriel", 60.0)].enumerated().map { index, speaker in
            ConversationSpeaker(label: "Speaker \(index + 1)", speechSeconds: speaker.1, embedding: [], naming: .named(speaker.0, similarity: 0.9))
        }
        let result = ProcessedConversation(transcript: Transcript(language: .hebrew, segments: segments), speakers: speakers, turns: turns, notes: notes)
        try library.save(result, for: info.id)
        return (library, info.id)
    }

    private func server(_ library: ConversationLibrary, allowed: Bool = true, changes: Changes = Changes()) -> MCPServer {
        MCPServer(
            store: library, version: "1.0", user: { "Gabriel" }, allowed: { allowed }, didChange: { changes.ids.append($0) },
            now: { Self.monday.addingTimeInterval(86_400) }
        )
    }

    private func send(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": params]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let reply = server.handle(line) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
    }

    private func result(_ reply: [String: Any]) -> [String: Any] {
        reply["result"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ reply: [String: Any]) -> Int? {
        (reply["error"] as? [String: Any])?["code"] as? Int
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any] = [:]) -> (text: String, failed: Bool) {
        let result = result(send(server, "tools/call", ["name": tool, "arguments": arguments]))
        let content = result["content"] as? [[String: Any]] ?? []
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    @Test func anEarlierClientStartsWithInitialize() throws {
        let (library, _) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)

        let started = result(send(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-ai", "version": "1"]]))
        let unknown = result(send(server, "initialize", ["protocolVersion": "2024-01-01"]))
        let serverName = (started["serverInfo"] as? [String: Any])?["name"] as? String
        let tools = (started["capabilities"] as? [String: Any])?["tools"] as? [String: Any]

        #expect(started["protocolVersion"] as? String == "2025-06-18")
        #expect(unknown["protocolVersion"] as? String == "2025-11-25")
        #expect(serverName == "bekitzur")
        #expect(tools?.isEmpty == false)
        #expect(server.handle(#"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#) == nil)
        #expect(server.client == "Claude")
    }

    @Test func aCurrentClientNamesItsVersionInEachRequest() throws {
        let (library, _) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)
        func meta(_ version: String) -> [String: Any] {
            ["_meta": ["io.modelcontextprotocol/protocolVersion": version, "io.modelcontextprotocol/clientInfo": ["name": "cursor-vscode", "version": "2"]]]
        }

        let discovered = result(send(server, "server/discover", meta(MCPServer.protocolVersion)))
        let refused = send(server, "tools/list", meta("2030-01-01"))
        let listed = result(send(server, "tools/list", meta(MCPServer.protocolVersion)))
        let supported = ((refused["error"] as? [String: Any])?["data"] as? [String: Any])?["supported"] as? [String]

        #expect(discovered["supportedVersions"] as? [String] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        #expect(discovered["resultType"] as? String == "complete")
        #expect(discovered["instructions"] as? String == MCPServer.instructions)
        #expect(errorCode(refused) == -32022)
        #expect(supported == MCPServer.supported)
        #expect((listed["tools"] as? [[String: Any]])?.count == MCPServer.Tool.allCases.count)
        #expect(server.client == "Cursor")
    }

    /// Only editing the Notes changes anything, and the AI app is told so.
    @Test func eachToolSaysWhetherItChangesAnything() throws {
        let (library, _) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let tools = result(send(server(library), "tools/list"))["tools"] as? [[String: Any]] ?? []
        var readOnly: [String: Bool] = [:]
        for tool in tools { readOnly[tool["name"] as? String ?? ""] = (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool }

        #expect(readOnly == ["find_conversations": true, "list_people": true, "get_conversation": true, "get_transcript": true, "edit_notes": false])
    }

    @Test func nothingWorksUntilTheUserLetsAIApps() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let found = call(server(library, allowed: false), "get_conversation", ["conversation": id])

        #expect(found.failed)
        #expect(found.text == MCPServer.notAllowed)
    }

    @Test func conversationsAreFoundByWordsPersonAndDay() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)

        let byWords = call(server, "find_conversations", ["text": "RUNBOOK"])
        let byPerson = call(server, "find_conversations", ["person": "dana"])
        let byTheUser = call(server, "find_conversations", ["person": "Gabriel"])
        let onTheDay = call(server, "find_conversations", ["after": "2026-11-02", "before": "2026-11-02"])
        let later = call(server, "find_conversations", ["after": "2026-11-03"])
        let notADay = call(server, "find_conversations", ["after": "last week"])

        #expect(byWords.text.hasPrefix("- \(id): “Release sync”; Monday, 2 November 2026"))
        #expect(byWords.text.contains("with Dana, Ron; 1 Action Item, 1 open"))
        #expect(byWords.text.contains("Found in: “"))
        #expect(byPerson.text.hasPrefix("- \(id):"))
        #expect(byTheUser.text == "No Conversation fits that.")
        #expect(onTheDay.text.hasPrefix("- \(id):"))
        #expect(later.text == "No Conversation fits that.")
        #expect(notADay.failed)
    }

    @Test func thePeopleLeaveTheUserOut() throws {
        let (library, _) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let people = call(server(library), "list_people")

        #expect(people.text == "- Dana: 1 Conversation, the last on Monday, 2 November 2026\n- Ron: 1 Conversation, the last on Monday, 2 November 2026")
    }

    @Test func aConversationListsItsNotesByTheNamesEditsUse() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let conversation = call(server(library), "get_conversation", ["conversation": id])

        #expect(!conversation.failed)
        #expect(conversation.text.contains("Speakers: Dana (5 minutes), Ron (2 minutes), Gabriel (1 minute)"))
        #expect(conversation.text.contains("Notes language: English\nNotes version, for edit_notes: \(MCPServer.version(of: notes))"))
        #expect(conversation.text.hasSuffix("""
            Title: Release sync
            Summary: The release moves to Thursday.

            Decisions:
            D1. Release on Thursday [from T001 at 0:05]
            Action items:
            A1. Update the runbook (owner: Ron) [from T002 at 1:10]
            Open questions:
            Q1. Who tells the customers?
            """))
    }

    @Test func theTranscriptComesAsNumberedTurnsOrAStretchOfThem() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)

        let all = call(server, "get_transcript", ["conversation": id])
        let fromTheSecondMinute = call(server, "get_transcript", ["conversation": id, "from_minute": 1])
        let theFirstMinute = call(server, "get_transcript", ["conversation": id, "to_minute": 1])
        let backwards = call(server, "get_transcript", ["conversation": id, "from_minute": 5, "to_minute": 1])

        #expect(all.text.hasSuffix("[T001 0:05] Dana: נדחה את ה-release ליום חמישי.\n[T002 1:10] Ron: אני אעדכן את ה-runbook."))
        #expect(fromTheSecondMinute.text.hasSuffix("\n\n[T002 1:10] Ron: אני אעדכן את ה-runbook."))
        #expect(theFirstMinute.text.hasSuffix("\n\n[T001 0:05] Dana: נדחה את ה-release ליום חמישי."))
        #expect(backwards.text.hasSuffix("Nothing was said then."))
    }

    /// The change is saved, the open app is told, and the Conversation's chat shows it with Undo.
    @Test func theNotesChangeAsAskedAndTheAppCanUndoIt() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let changes = Changes()
        let server = server(library, changes: changes)
        _ = send(server, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-ai", "version": "1"]])
        let edits: [[String: Any]] = [
            ["action": "add", "section": "action_item", "text": "Tell the customers", "owner": "Dana", "due": "2026-11-05 9:30"],
            ["action": "change", "item": "a1", "done": true],
        ]

        let edited = call(server, "edit_notes", ["conversation": id, "notes_version": MCPServer.version(of: notes), "edits": edits, "reason": "As agreed by email"])
        let saved = try #require(library.result(for: id))
        let exchange = try #require(library.chat(for: id).last)

        #expect(!edited.failed)
        #expect(edited.text.contains("- Added Action Item: Tell the customers\n- Changed Action Item: Update the runbook"))
        #expect(saved.notes.actionItems.last == ActionItem(text: "Tell the customers", owner: "Dana", duePhrase: "2026-11-05 9:30", dueDate: "2026-11-05", dueTime: "09:30"))
        #expect(saved.notes.actionItems.first?.done == true)
        #expect(saved.notesEdited == true)
        #expect(exchange.from == "Claude")
        #expect(exchange.message == "As agreed by email")
        #expect(exchange.answer == nil)
        #expect(exchange.notesBefore == notes)
        #expect(exchange.notesAfter == saved.notes)
        #expect(changes.ids == [id])
    }

    @Test func notesThatChangedSinceTheyWereReadAreLeftAlone() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let changes = Changes()

        let edited = call(server(library, changes: changes), "edit_notes", [
            "conversation": id, "notes_version": "0123456789ab", "edits": [["action": "remove", "item": "Q1"]],
        ])

        #expect(edited.failed)
        #expect(library.result(for: id)?.notes == notes)
        #expect(library.chat(for: id).isEmpty)
        #expect(changes.ids.isEmpty)
    }

    @Test func aNewTitleRenamesTheConversation() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }

        _ = call(server(library), "edit_notes", [
            "conversation": id, "notes_version": MCPServer.version(of: notes), "edits": [["action": "title", "text": "Thursday release"]],
        ])
        let info = try #require(library.all().first)

        #expect(info.title == "Thursday release")
        #expect(info.renamed == true)
    }

    @Test(arguments: [
        // No Conversation by that ID.
        #"{"conversation": "2020-01-01-000000"}"#,
        // An edit with no section to add to.
        #"{"edits": [{"action": "add", "text": "Tell support"}]}"#,
        // An action the Notes don't have.
        #"{"edits": [{"action": "rewrite"}]}"#,
        // Edits that change nothing.
        #"{"edits": [{"action": "remove", "item": "Q9"}]}"#,
    ])
    func aToolsMistakeIsToldToTheModel(_ arguments: String) throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let parsed = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        let mistaken = try #require(parsed as? [String: Any])
        var given: [String: Any] = ["conversation": id, "notes_version": MCPServer.version(of: notes)]
        given.merge(mistaken) { _, mistake in mistake }

        let edited = call(server(library), "edit_notes", given)

        #expect(edited.failed)
        #expect(!edited.text.isEmpty)
        #expect(library.result(for: id)?.notes == notes)
    }

    @Test func requestsTheServerCantTakeAreErrors() throws {
        let (library, _) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)

        let unknownMethod = send(server, "resources/list")
        let unknownTool = send(server, "tools/call", ["name": "delete_everything"])
        let notJSON = (try? JSONSerialization.jsonObject(with: Data((server.handle("{not json") ?? "").utf8))) as? [String: Any] ?? [:]

        #expect(errorCode(unknownMethod) == -32601)
        #expect(errorCode(unknownTool) == -32602)
        #expect(errorCode(notJSON) == -32700)
    }

    /// Where MCP servers aren't allowed, an AI agent runs the tools from its terminal, through the same checks.
    @Test func anAgentInATerminalRunsAToolByName() throws {
        let (library, id) = try library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let server = server(library)

        let found = server.call("find_conversations", arguments: ["text": "runbook"], by: "Cursor")
        let unknown = server.call("search", arguments: [:], by: nil)
        let refused = self.server(library, allowed: false).call("list_people", arguments: [:], by: "Cursor")

        #expect(!found.failed)
        #expect(found.text.hasPrefix("- \(id):"))
        #expect(server.client == "Cursor")
        #expect(unknown.failed)
        #expect(unknown.text.contains("find_conversations"))
        #expect(refused.text == MCPServer.notAllowed)
    }

    @Test func theToolsAreListedForTheTerminal() {
        let help = MCPServer.toolsHelp

        #expect(help.contains("edit_notes: Changes a Conversation's Notes"))
        #expect(help.contains("""

              conversation (string, required): The Conversation's ID, from find_conversations.
              edits (a list of objects, required)
                action (add | change | remove | title | summary, required)
            """))
    }

    @Test func theSkillTellsAnAgentHowToRunThem() {
        let skill = MCPServer.skill(command: "/Users/dana/Applications/Bekitzur.app/Contents/MacOS/Bekitzur", app: "Cursor")

        #expect(skill.hasPrefix("---\nname: bekitzur\ndescription: Reads and edits the user's recorded meetings and calls"))
        #expect(skill.contains(#""/Users/dana/Applications/Bekitzur.app/Contents/MacOS/Bekitzur" --tool find_conversations '{"person": "Dana", "after": "2026-11-02"}' --as "Cursor""#))
        #expect(skill.contains(#"`"/Users/dana/Applications/Bekitzur.app/Contents/MacOS/Bekitzur" --tools` lists the tools"#))
    }

    @Test(arguments: [
        (["name": "claude-ai", "version": "1"], "Claude"),
        (["name": "claude-code", "version": "1"], "Claude Code"),
        (["name": "cursor-vscode", "version": "1"], "Cursor"),
        (["name": "cursor-vscode", "title": "Cursor Nightly", "version": "1"], "Cursor Nightly"),
        (["name": "my-agent", "version": "1"], "my-agent"),
    ] as [([String: String], String)])
    func anAIAppIsCalledByItsName(_ client: [String: String], _ name: String) {
        #expect(MCPServer.name(of: client) == name)
    }
}
