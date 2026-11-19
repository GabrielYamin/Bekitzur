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
    /// A note the same as a Decision changes nothing, even one that says otherwise, and any other note adds what it
    /// says, including one the model called the same as an item it shares no words with.
    @Test func yourNotesAddToWhatWasSaid() throws {
        let yourNotes = [
            UserNote(at: 194, text: "Thursday"),
            UserNote(at: 213, text: "payments - Avi, by Sunday"),
            UserNote(at: 214, text: "release on Friday instead"),
            UserNote(at: 215, text: "[ ] who tells support"),
            UserNote(at: 230, text: "support is on call this week"),
            UserNote(at: 231, text: "# Release"),
        ]
        let reply = #"""
        [{"note": 1, "same_as": "D1", "add": {"decision": {"text": "Ship 2.4 on Thursday", "source_turns": ["T001"], "quote": ""}}},
         {"note": 2, "same_as": "A1", "add": {"action_item": {"text": "Check the payment flow by Sunday", "owner": "Avi", "due_phrase": "by Sunday", "source_turns": ["T002"], "quote": ""}}},
         {"note": 3, "same_as": "D1", "add": {"decision": {"text": "Ship 2.4 on Friday instead of Thursday", "source_turns": ["T001"], "quote": ""}}},
         {"note": 4, "same_as": "A1", "add": {"action_item": {"text": "Tell support about the release", "owner": null, "due_phrase": null, "source_turns": [], "quote": ""}}},
         {"note": 5, "same_as": null, "add": {"summary": "Support is on call this week."}},
         {"note": 6, "same_as": "D1"}]
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let checked = try decoder.decode([NotesWriter.CheckedNote].self, from: Data(reply.utf8))

        let notes = NotesWriter.adding(checked, of: yourNotes, to: draft)
        let payments = notes.actionItems.first

        #expect(notes.decisions.map(\.text) == draft.decisions.map(\.text))
        #expect(notes.decisions.first?.withYourNotes == [yourNotes[0].id, yourNotes[2].id, yourNotes[5].id])
        #expect(payments?.owner == "Ron")
        #expect(payments?.duePhrase == "by Sunday")
        #expect(payments?.withYourNotes == [yourNotes[1].id])
        #expect(notes.actionItems.map(\.text) == ["Check the payment flow", "Tell support about the release"])
        #expect(notes.actionItems.last?.fromYourNote == yourNotes[3].id)
        #expect(notes.summary == "The team planned the release. Support is on call this week.")
    }

    /// A note can only be the same as an item the Notes have, not the summary, since a note the same as no item, or as
    /// a summary that doesn't say it, is lost. A to-do can only be an action item, so the model can't take one for the
    /// Decision on its subject, and a heading only goes with an item.
    @Test func eachNoteHasAnEntryInOrderAboutTheNotesItems() {
        let yourNotes = [UserNote(at: 0, text: "Thursday"), UserNote(at: 1, text: "[ ] tell support"), UserNote(at: 2, text: "# Release")]

        let grammar = NotesWriter.yourNotesGrammar(for: yourNotes, in: draft)
        let withoutItems = NotesWriter.yourNotesGrammar(for: yourNotes, in: Notes())

        #expect(grammar.hasPrefix(#"root ::= "[" ws note1 "," ws note2 "," ws note3 ws "]""#))
        #expect(grammar.contains(#"note1 ::= "{" ws "\"note\":" ws "1" "," ws "\"same_as\":" ws same-any ws "}""#))
        #expect(grammar.contains(#"note2 ::= "{" ws "\"note\":" ws "2" "," ws "\"same_as\":" ws same-task ws "}""#))
        #expect(grammar.contains(#"note3 ::= "{" ws "\"note\":" ws "3" "," ws "\"same_as\":" ws same-heading ws "}""#))
        #expect(grammar.contains(#"same-any ::= ("\"A1\"" | "\"D1\"" | "null") "," ws "\"add\":" ws addition"#))
        #expect(grammar.contains(#"same-task ::= ("\"A1\"" | "null") "," ws "\"add\":" ws "{" ws "\"action_item\":""#))
        #expect(grammar.contains(#"same-heading ::= ("\"A1\"" | "\"D1\"" | "null")"# + "\n"))
        #expect(!grammar.contains(#""\"summary\"""#))
        #expect(!grammar.contains(#""\"A2\"""#))
        #expect(withoutItems.contains(#"same-any ::= ("null") "," ws "\"add\":" ws addition"#))
        #expect(withoutItems.contains(#"same-heading ::= ("null")"# + "\n"))
    }
}
