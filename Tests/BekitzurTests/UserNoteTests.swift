import Foundation
import Testing
@testable import BekitzurDomain

struct UserNoteTests {
    @Test(arguments: [
        ("# Release 2.4", "heading", "Release 2.4"),
        ("[ ] who tells support", "task", "who tells support"),
        ("[]call Avi", "task", "call Avi"),
        ("  Thursday, if the regression is green", "point", "Thursday, if the regression is green"),
    ])
    func aLineIsAHeadingATaskOrAPoint(text: String, kind: String, words: String) {
        let note = UserNote(at: 0, text: text)
        let name = switch note.kind {
        case .heading: "heading"
        case .task: "task"
        case .point: "point"
        }

        #expect(name == kind)
        #expect(note.words == words)
    }

    /// A note sits beside what was said just before it was written, or by an item its own words made, like a task the
    /// meeting never talked about; one about nothing in the Notes sits beside the summary.
    @Test func eachNoteSitsBesideTheItemItsAbout() {
        let turns = [
            Turn(id: "T001", speaker: "Dana", text: "מעלים את 2.4 ביום חמישי", start: 192, end: 199),
            Turn(id: "T002", speaker: "Ron", text: "אני אבדוק את ה-payment flow", start: 211, end: 216),
            Turn(id: "T003", speaker: "Speaker 4", text: "אני אדבר איתם היום", start: 250, end: 252),
        ]
        let written = Notes(
            title: "Release sync",
            summary: "Release 2.4 goes out on Thursday.",
            decisions: [Decision(text: "Release 2.4 on Thursday, after the full regression passes.", sourceTurns: ["T001"])],
            actionItems: [
                ActionItem(text: "Talk to the mobile team about the API change", owner: "Speaker 4", sourceTurns: ["T003"]),
                ActionItem(text: "Check the payment flow on staging", owner: "Ron", sourceTurns: ["T002"]),
                ActionItem(text: "Tell customer support about the new checkout"),
            ],
            openQuestions: []
        )
        let thursday = UserNote(at: 194, text: "Thursday, if the regression is green")
        let payments = UserNote(at: 213, text: "Ron → payments on staging, tmrw 4pm")
        let before = UserNote(at: 180, text: "release date?")
        let support = UserNote(at: 256, text: "[ ] who tells support about the new checkout")
        let lunch = UserNote(at: 900, text: "lunch")
        let empty = UserNote(at: 901, text: "  ")

        let places = UserNote.places(of: [thursday, payments, before, support, lunch, empty], in: written, turns: turns)

        #expect(places[thursday.id] == .decision(0))
        #expect(places[payments.id] == .actionItem(1))
        #expect(places[before.id] == .decision(0))
        #expect(places[support.id] == .actionItem(2))
        #expect(places[lunch.id] == .summary)
        #expect(places[empty.id] == nil)
    }

    /// An item a note made sits beside that note, whatever was said around it.
    @Test func aNoteSitsBesideTheItemItMade() {
        let turns = [Turn(id: "T001", speaker: "Dana", text: "מעלים את 2.4 ביום חמישי", start: 192, end: 199)]
        let note = UserNote(at: 195, text: "[ ] send Maya the deck")
        var made = ActionItem(text: "Send Maya the deck", sourceTurns: ["T001"])
        made.yourNote = note.id
        let written = Notes(
            title: "Release sync",
            summary: "Release 2.4 goes out on Thursday.",
            decisions: [Decision(text: "Release 2.4 on Thursday", sourceTurns: ["T001"])],
            actionItems: [made],
            openQuestions: []
        )

        let places = UserNote.places(of: [note], in: written, turns: turns)

        #expect(places[note.id] == .actionItem(0))
    }
}
