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

        let request = NotesWriter.yourNotesRequest(notes, draft: draft, turns: turns, in: .hebrew)

        #expect(request.contains("""
        1. (during T001) Thursday, if the regression is green
        2. (during T002) [ ] who tells support
        3. (during T001) before anyone spoke
        """))
        #expect(request.contains("D1. Ship 2.4 on Thursday\nA1. Check the payment flow"))
        #expect(request.hasSuffix("Every field is in Hebrew."))
    }

    /// The notes only add to the draft: what the transcript gave stays as it is, and what a note adds keeps the note.
    @Test func whatYourNotesAddComesAfterTheDraft() throws {
        let yourNotes = [
            UserNote(at: 194, text: "Thursday"),
            UserNote(at: 215, text: "[ ] who tells support"),
            UserNote(at: 230, text: "support is on call this week"),
        ]
        let reply = #"""
        [{"note": 1, "in_notes": "D1"},
         {"note": 2, "in_notes": null, "add": {"action_item": {"text": "Tell support", "owner": null, "due_phrase": null, "source_turns": [], "quote": ""}}},
         {"note": 3, "in_notes": null, "add": {"summary": "Support is on call this week."}}]
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let checked = try decoder.decode([NotesWriter.CheckedNote].self, from: Data(reply.utf8))

        let notes = NotesWriter.adding(checked, of: yourNotes, to: draft)

        #expect(notes.decisions == draft.decisions)
        #expect(notes.actionItems.map(\.text) == ["Check the payment flow", "Tell support"])
        #expect(notes.actionItems.map(\.yourNote) == [nil, yourNotes[1].id])
        #expect(notes.actionItems.last?.owner == nil)
        #expect(notes.summary == "The team planned the release. Support is on call this week.")
    }

    @Test func eachNoteHasAnEntryInOrder() {
        let grammar = NotesWriter.yourNotesGrammar(count: 2)

        #expect(grammar.hasPrefix(#"root ::= "[" ws note1 "," ws note2 ws "]""#))
        #expect(grammar.contains(#"note2 ::= "{" ws "\"note\":" ws "2""#))
        #expect(!grammar.contains("note3"))
    }
}
