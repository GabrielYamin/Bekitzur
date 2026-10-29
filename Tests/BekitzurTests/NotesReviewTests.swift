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

    @Test func turnIDsAfterAnItemsTextAreLeftOut() {
        #expect(NotesWriter.withoutTurnIDs("How do we share best practices? (T026)") == "How do we share best practices?")
        #expect(NotesWriter.withoutTurnIDs("Test the new fields tomorrow. (T008, T009)") == "Test the new fields tomorrow.")
        #expect(NotesWriter.withoutTurnIDs("Move to the new client (in unbiased infra).") == "Move to the new client (in unbiased infra).")
    }

    @Test func eachOpenQuestionComesWithWhatWasSaidFromWhereItWasAsked() {
        var turns = self.turns
        turns[4].text = (1...400).map { "w\($0)" }.joined(separator: " ")
        turns[5].text = (1...100).map { "v\($0)" }.joined(separator: " ")

        let request = NotesWriter.questionRequest(draft.openQuestions[1], number: 2, of: 4, turns: turns)

        #expect(request.hasPrefix("Open question 2 of 4: Does product want CSV too? (T005)"))
        #expect(!request.contains("[T004]"))
        // Its own turn ends with what was asked; the turns after it start with any answer.
        #expect(request.contains("[T005] Ron: w101 w102") && request.contains("w400\n"))
        #expect(request.contains("[T006] Ron: v1 v2") && request.contains("v80 …\n"))
        #expect(request.contains("[T010] Ron: …"))
    }

    @Test func onlyATurnAfterTheQuestionCanAnswerIt() {
        let question = draft.openQuestions[3]
        func answer(_ turn: String?) -> String? {
            NotesWriter.laterAnswer(to: question, NotesWriter.CheckedQuestion(answeredIn: turn, kind: "open"), turns: turns)?.id
        }

        #expect(answer("T009") == "T009")
        #expect(answer("T002") == nil)
        #expect(answer("T007") == nil)
        #expect(answer("T950") == nil)
        #expect(answer(nil) == nil)
    }

    @Test func theAnswerTheSearchFoundIsShownOnItsOwn() {
        let request = NotesWriter.answerRequest(draft.openQuestions[1], Turn(id: "T009", speaker: "Omer", text: "Build Parquet only for now."))

        #expect(request.hasPrefix(#"Does this turn answer the question "Does product want CSV too?"?"#))
        #expect(request.contains("[T009] Omer: Build Parquet only for now."))
    }
}
