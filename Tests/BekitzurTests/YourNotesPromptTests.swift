import Foundation
import Testing
@testable import BekitzurDomain
@testable import BekitzurNotes

struct YourNotesPromptTests {
    private let turns = [
        Turn(id: "T001", speaker: "Dana", text: "מעלים את 2.4 ביום חמישי", start: 192, end: 199),
        Turn(id: "T002", speaker: "Ron", text: "אני אבדוק את ה-payment flow", start: 211, end: 216),
    ]
    private let draft = Notes(
        title: "Release",
        summary: "The team planned the release.",
        decisions: [Decision(text: "Ship 2.4 on Thursday", sourceTurns: ["T001"], quote: "מעלים את 2.4 ביום חמישי")],
        actionItems: [ActionItem(text: "Check the payment flow", owner: "Ron", sourceTurns: ["T002"], quote: "אני אבדוק את ה-payment flow")],
        openQuestions: []
    )

    /// The transcript shows turns, not times, so each note says which turn was being said when it was written; and the
    /// draft's items are numbered for the model to say which one already has a note.
    @Test func yourNotesAreListedWithTheTurnBeingSaid() {
        let notes = [
            UserNote(at: 194, text: "Thursday, if the regression is green"),
            UserNote(at: 215, text: "[ ] who tells support "),
            UserNote(at: 100, text: "before anyone spoke"),
        ]

        let request = NotesWriter.yourNotesRequest(notes, by: "Dana", draft: draft, turns: turns, in: .hebrew)

        #expect(request.contains("""
        1. (during T001) Thursday, if the regression is green
        2. (during T002) [ ] who tells support
        3. (during T001) before anyone spoke
        """))
        #expect(request.contains("D1. Ship 2.4 on Thursday\nA1. Check the payment flow (owner: Ron; due: none)"))
        #expect(request.contains(#"The user is "Dana""#))
        #expect(request.hasSuffix("Every field is in Hebrew."))
    }

    /// What was said stands, and a note adds to it: an Owner or a due phrase only where the same action item has none.
    /// A note about the same Decision changes nothing, even one that says otherwise, and one about nothing in the Notes
    /// adds what it says.
    @Test func yourNotesAddToWhatWasSaid() throws {
        let yourNotes = [
            UserNote(at: 194, text: "Thursday"),
            UserNote(at: 213, text: "payments - Avi, by Sunday"),
            UserNote(at: 214, text: "release on Friday instead"),
            UserNote(at: 215, text: "[ ] who tells support"),
            UserNote(at: 230, text: "support is on call this week"),
        ]
        let reply = #"""
        [{"note": 1, "same_as": "D1"},
         {"note": 2, "same_as": "A1", "owner": "Avi", "due_phrase": "by Sunday"},
         {"note": 3, "same_as": "D1"},
         {"note": 4, "same_as": null, "add": {"action_item": {"text": "Tell support", "owner": null, "due_phrase": null, "source_turns": [], "quote": ""}}},
         {"note": 5, "same_as": null, "add": {"summary": "Support is on call this week."}}]
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let checked = try decoder.decode([NotesWriter.CheckedNote].self, from: Data(reply.utf8))

        let notes = NotesWriter.adding(checked, of: yourNotes, to: draft)
        let payments = notes.actionItems.first

        #expect(notes.decisions.map(\.text) == draft.decisions.map(\.text))
        #expect(notes.decisions.first?.withYourNotes == [yourNotes[0].id, yourNotes[2].id])
        #expect(payments?.owner == "Ron")
        #expect(payments?.duePhrase == "by Sunday")
        #expect(payments?.withYourNotes == [yourNotes[1].id])
        #expect(notes.actionItems.map(\.text) == ["Check the payment flow", "Tell support"])
        #expect(notes.actionItems.last?.fromYourNote == yourNotes[3].id)
        #expect(notes.summary == "The team planned the release. Support is on call this week.")
    }

    /// A to-do can only be an action item, so the model can't take one for the Decision on its subject.
    @Test func eachNoteHasAnEntryInOrderAndAToDoIsAnActionItem() {
        let grammar = NotesWriter.yourNotesGrammar(for: [UserNote(at: 0, text: "Thursday"), UserNote(at: 1, text: "[ ] tell support")])

        #expect(grammar.hasPrefix(#"root ::= "[" ws note1 "," ws note2 ws "]""#))
        #expect(grammar.contains(#"note1 ::= "{" ws "\"note\":" ws "1" "," ws "\"same_as\":" ws same-any ws "}""#))
        #expect(grammar.contains(#"note2 ::= "{" ws "\"note\":" ws "2" "," ws "\"same_as\":" ws same-task ws "}""#))
        #expect(!grammar.contains("note3"))
    }
}
