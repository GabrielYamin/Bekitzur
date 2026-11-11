import Foundation
import Testing
@testable import BekitzurDomain

/// Changes the chat makes to the Notes, naming items by their places in the Notes it saw.
struct NotesEditTests {
    private let notes = Notes(
        title: "Release sync",
        summary: "The release moves to Thursday.",
        decisions: [Decision(text: "Release on Thursday"), Decision(text: "Freeze on Wednesday")],
        actionItems: [
            ActionItem(text: "Fix the login bug", owner: "Dana", duePhrase: "מחר", dueDate: "2026-11-05"),
            ActionItem(text: "Update the runbook", owner: "Speaker 2"),
            ActionItem(text: "Tell support", owner: "Ron"),
        ],
        openQuestions: [OpenQuestion(text: "Who tells the customers?")]
    )

    private func applying(_ edits: [NotesEdit]) -> (notes: Notes, applied: [AppliedEdit]) {
        notes.applying(edits) { phrase in phrase == "Thursday at 4pm" ? ("2026-11-12", "16:00") : nil }
    }

    /// A reply can remove an item and change one after it: both name the items as the chat saw them.
    @Test func itemsAreNamedByTheirPlacesBeforeTheReply() {
        let (changed, applied) = applying([.remove(item: "A1"), .change(item: "A3", text: nil, owner: "Maya", due: nil, done: nil)])

        #expect(changed.actionItems.map(\.text) == ["Update the runbook", "Tell support"])
        #expect(changed.actionItems.last?.owner == "Maya")
        #expect(applied == [
            AppliedEdit(kind: .removed, section: .actionItem, text: "Fix the login bug"),
            AppliedEdit(kind: .changed, section: .actionItem, text: "Tell support"),
        ])
    }

    @Test func eachKindOfChange() {
        let (changed, applied) = applying([
            .add(.decision, text: "Ship behind a flag", owner: nil, due: nil),
            .add(.actionItem, text: "Book the review", owner: "Dana", due: "Thursday at 4pm"),
            .add(.openQuestion, text: "Is QA ready?", owner: nil, due: nil),
            .change(item: "D2", text: "Freeze on Tuesday", owner: nil, due: nil, done: nil),
            .change(item: "A2", text: nil, owner: nil, due: nil, done: true),
            .remove(item: "Q1"),
            .title("Release sync, moved"),
            .summary("Thursday, behind a flag."),
        ])

        #expect(changed.decisions.map(\.text) == ["Release on Thursday", "Freeze on Tuesday", "Ship behind a flag"])
        #expect(changed.actionItems.last == ActionItem(text: "Book the review", owner: "Dana", duePhrase: "Thursday at 4pm", dueDate: "2026-11-12", dueTime: "16:00"))
        #expect(changed.actionItems[1].done == true)
        #expect(changed.openQuestions.map(\.text) == ["Is QA ready?"])
        #expect(changed.title == "Release sync, moved")
        #expect(changed.summary == "Thursday, behind a flag.")
        #expect(applied.count == 8)
    }

    /// An empty owner or due takes it off; one the resolver can't date stays as said.
    @Test func anOwnerOrADueCanBeTakenOff() {
        let (changed, _) = applying([
            .change(item: "A1", text: nil, owner: "", due: "", done: nil),
            .change(item: "A2", text: nil, owner: nil, due: "after the release", done: nil),
        ])

        #expect(changed.actionItems[0].owner == nil)
        #expect(changed.actionItems[0].duePhrase == nil && changed.actionItems[0].dueDate == nil)
        #expect(changed.actionItems[1].duePhrase == "after the release" && changed.actionItems[1].dueDate == nil)
    }

    /// The model can name an item the Notes don't have, or "change" something to what it already is.
    @Test func editsThatChangeNothingDontCount() {
        let (changed, applied) = applying([
            .remove(item: "A7"),
            .change(item: "Q2", text: nil, owner: "Ron", due: nil, done: nil),
            .title("Release sync"),
            .change(item: "D1", text: "Release on Thursday", owner: nil, due: nil, done: nil),
            .change(item: "A2", text: nil, owner: nil, due: nil, done: false),
            .add(.decision, text: "  ", owner: nil, due: nil),
        ])

        #expect(changed == notes)
        #expect(applied.isEmpty)
    }

    /// An item named past the end of the Notes the chat saw can only be a new one.
    @Test func aChangeToAnItemPastTheEndAddsIt() {
        let (changed, applied) = applying([
            .change(item: "A7", text: "Send the mapping", owner: "Dana", due: nil, done: nil),
            .change(item: "Q9", text: nil, owner: nil, due: nil, done: true),
        ])

        #expect(changed.actionItems.last == ActionItem(text: "Send the mapping", owner: "Dana"))
        #expect(changed.actionItems.count == notes.actionItems.count + 1)
        #expect(applied == [AppliedEdit(kind: .added, section: .actionItem, text: "Send the mapping")])
    }

    @Test func anItemRemovedTwiceIsRemovedOnce() {
        let (changed, applied) = applying([.remove(item: "D1"), .remove(item: "D1")])

        #expect(changed.decisions.map(\.text) == ["Freeze on Wednesday"])
        #expect(applied == [AppliedEdit(kind: .removed, section: .decision, text: "Release on Thursday")])
    }

    @Test func aChatIsKeptAsItWasSaid() throws {
        var exchange = ChatExchange(message: "Add an item for Dana")
        exchange.answer = Answer(text: "Added it.", evidence: [Evidence(turn: "T004", quote: "אני אבדוק", speaker: "Dana", start: 12)])
        exchange.edits = [AppliedEdit(kind: .added, section: .actionItem, text: "Check it")]
        exchange.notesBefore = notes
        exchange.notesAfter = applying([.add(.actionItem, text: "Check it", owner: "Dana", due: nil)]).notes
        exchange.reply = #"{"asks": "change", "edits": [{"add": "action_item", "text": "Check it", "owner": "Dana", "due": null}], "evidence": []}"# + "\nAnswer: Added it."
        exchange.reference = ChatReference(
            ChatCandidate(id: "2026-11-02-120000", title: "Kickoff", date: Date(timeIntervalSince1970: 1_793_620_800), people: ["Dana"]), notes: notes
        )

        let saved = try JSONDecoder().decode([ChatExchange].self, from: JSONEncoder().encode([exchange]))

        #expect(saved == [exchange])
    }

    @Test func aChatSavedBeforeRepliesWereKeptStillReads() throws {
        let saved = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "message": "Who decides?", "edits": [], "undone": false}]"#

        let chat = try JSONDecoder().decode([ChatExchange].self, from: Data(saved.utf8))

        #expect(chat.map(\.message) == ["Who decides?"])
        #expect(chat.first?.reply == nil)
    }
}
