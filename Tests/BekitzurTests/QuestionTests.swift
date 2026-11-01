import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurNotes

struct QuestionTests {
    private let turns = [
        Turn(id: "T001", speaker: "Ron", text: "אני עובד על ה-gateway, לחבר את ה-flow החדש ל-Kafka.", start: 44, end: 52),
        Turn(id: "T002", speaker: "Maya", text: "אז זה יהיה עם flag, לא? כן, עם flag.", start: 498, end: 503),
    ]

    @Test func anAnswerKeepsTheQuotesThatAreInTheirTurns() {
        let reply = #"{"evidence": [{"turn": "T001", "quote": "ה-flow החדש ל-kafka"}], "answer": "Ron is working on the new flow."}"#

        let answer = ConversationQuestions.answer(from: reply, turns: turns)

        #expect(answer.text == "Ron is working on the new flow.")
        #expect(answer.evidence == [Evidence(turn: "T001", quote: "ה-flow החדש ל-kafka", speaker: "Ron", start: 44)])
    }

    @Test func turnNumbersWrittenIntoAnAnswerAreTakenOut() {
        let reply = #"{"evidence": [{"turn": "T001", "quote": "ה-flow החדש ל-kafka"}], "answer": "Ron is on the new flow [T001], with the old one (T001, T004) gone."}"#

        #expect(ConversationQuestions.answer(from: reply, turns: turns).text == "Ron is on the new flow, with the old one gone.")
    }

    @Test(arguments: [
        // Paraphrased, not quoted.
        #"{"evidence": [{"turn": "T001", "quote": "הוא עובד על הזרימה"}], "answer": "Ron works on the flow."}"#,
        // A real quote, attributed to the wrong turn.
        #"{"evidence": [{"turn": "T002", "quote": "ה-flow החדש"}], "answer": "Maya works on the flow."}"#,
        // A confident answer with no evidence.
        #"{"evidence": [], "answer": "The release moved to Thursday."}"#,
        // One word proves nothing.
        #"{"evidence": [{"turn": "T002", "quote": "flag"}], "answer": "They'll use a flag."}"#,
        // Evidence, but nothing to say.
        #"{"evidence": [{"turn": "T002", "quote": "עם flag"}], "answer": " "}"#,
        "not JSON",
    ])
    func withoutAQuoteThatChecksOutTheConversationDoesntSay(reply: String) {
        #expect(ConversationQuestions.answer(from: reply, turns: turns) == .notInConversation)
    }

    @Test func aChatThatStartsOverIsGivenTheAnswersTheUserSaw() {
        let ron = Answer(text: "Ron.", evidence: [Evidence(turn: "T001", quote: "a b"), Evidence(turn: "T004", quote: "c d"), Evidence(turn: "T001", quote: "e f")])

        let history = ConversationQuestions.history([
            (question: "Who works on the flow?", answer: ron),
            (question: "What's the budget?", answer: .notInConversation),
        ])

        #expect(history == "\n\nEarlier questions about this conversation, with the answers I was given:\n"
            + "- Q: Who works on the flow?\n  A: Ron. (T001, T004)\n"
            + "- Q: What's the budget?\n  A: The transcript doesn't say.")
        #expect(ConversationQuestions.history([]) == "")
    }

    @Test func onlyTheLastTenQuestionsAreCarriedOver() {
        let earlier = (1...12).map { (question: "Question \($0)?", answer: Answer.notInConversation) }

        let history = ConversationQuestions.history(earlier)

        #expect(!history.contains("Question 1?") && !history.contains("Question 2?"))
        #expect(history.contains("Question 3?") && history.contains("Question 12?"))
    }
}
