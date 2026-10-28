import Foundation
import Testing
@testable import BekitzurDomain
@testable import BekitzurNotes

struct NotesReviewTests {
    private let draft = Notes(
        title: "Sync",
        summary: "Short.",
        decisions: [
            Decision(text: "We'll do it tomorrow.", sourceTurns: ["T009"], quote: "נעשה את זה מחר"),
            Decision(text: "Mornings are quieter.", sourceTurns: ["T012"], quote: "בבוקר יותר שקט"),
        ],
        actionItems: [ActionItem(text: "Take it.", owner: "Maya", duePhrase: nil, dueDate: nil, sourceTurns: ["T034"], quote: "אני אקח את זה")],
        openQuestions: [
            OpenQuestion(text: "Who gets the report?", sourceTurns: ["T003"]),
            OpenQuestion(text: "Does product want CSV too?", sourceTurns: ["T005"]),
            OpenQuestion(text: "Will engineers still write code in ten years?", sourceTurns: ["T006"]),
            OpenQuestion(text: "Which region do we deploy to first?", sourceTurns: ["T007"]),
        ]
    )

    private let turns = (1...10).map { Turn(id: String(format: "T%03d", $0), speaker: "Ron", text: "…") }

    @Test func decisionsComeFirstThenActionItems() {
        let request = NotesWriter.reviewRequest(NotesWriter.reviewItems(draft))

        #expect(request.contains("1. We'll do it tomorrow. (T009)"))
        #expect(request.contains("3. Take it. (T034)"))
        #expect(!request.contains("Who gets the report?"))
    }

    @Test func theReplyHasAnEntryPerItemAndActionItemsCantBeDropped() {
        let grammar = NotesWriter.reviewGrammar(NotesWriter.reviewItems(draft))

        #expect(grammar.contains(#"root ::= "[" ws item1 "," ws item2 "," ws item3 ws "]""#))
        #expect(grammar.contains(#"item1 ::= "{" ws "\"item\":" ws "1" "," ws "\"text\":" ws (str | "null") ws "}""#))
        #expect(grammar.contains(#"item3 ::= "{" ws "\"item\":" ws "3" "," ws "\"text\":" ws str ws "}""#))
    }

    @Test func checkedItemsKeepTheirSourcesAndNullDropsADecision() {
        let checked = [
            NotesWriter.CheckedItem(item: 1, text: "Test the two new fields in the office tomorrow. (T008, T009)"),
            NotesWriter.CheckedItem(item: 2, text: nil),
            NotesWriter.CheckedItem(item: 3, text: "Fix the polling-interval bug."),
        ]

        let notes = NotesWriter.apply(checked, of: NotesWriter.reviewItems(draft), to: draft)

        #expect(notes.decisions.map(\.text) == ["Test the two new fields in the office tomorrow."])
        #expect(notes.decisions.first?.quote == "נעשה את זה מחר")
        #expect(notes.actionItems.map(\.text) == ["Fix the polling-interval bug."])
        #expect(notes.actionItems.first?.owner == "Maya")
        #expect(notes.openQuestions == draft.openQuestions)
    }

    @Test func eachOpenQuestionGetsAnEntryWithTheTurnThatAnswersIt() {
        let request = NotesWriter.questionsRequest(draft.openQuestions)
        let grammar = NotesWriter.questionsGrammar(count: 4)

        #expect(request.contains("2. Does product want CSV too? (T005)"))
        #expect(grammar.contains(#"root ::= "[" ws question1 "," ws question2 "," ws question3 "," ws question4 ws "]""#))
        #expect(grammar.contains(#"question4 ::= "{" ws "\"item\":" ws "4" "," ws "\"answered_in\":" ws (turn | "null") "," ws "\"kind\":" ws kind ws "}""#))
    }

    @Test func aQuestionAnsweredLaterOrNeverMeantIsDropped() {
        let checked = [
            NotesWriter.CheckedQuestion(item: 1, answeredIn: "T008", kind: "open"),
            NotesWriter.CheckedQuestion(item: 2, answeredIn: nil, kind: "open"),
            NotesWriter.CheckedQuestion(item: 3, answeredIn: nil, kind: "hypothetical"),
            // An "answer" before the question, or in no turn at all, answers nothing.
            NotesWriter.CheckedQuestion(item: 4, answeredIn: "T002", kind: "open"),
        ]

        let open = NotesWriter.stillOpen(draft.openQuestions, checked: checked, turns: turns)

        #expect(open.map(\.text) == ["Does product want CSV too?", "Which region do we deploy to first?"])
        #expect(NotesWriter.stillOpen([draft.openQuestions[0]], checked: [NotesWriter.CheckedQuestion(item: 1, answeredIn: "T950", kind: "open")], turns: turns).count == 1)
    }
}
