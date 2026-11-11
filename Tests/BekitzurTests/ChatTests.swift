import Foundation
import Testing
@testable import BekitzurDomain
@testable import BekitzurNotes

/// A chat about a Conversation: answers checked against its Transcript and Notes, and changes to the Notes.
struct ChatTests {
    private let turns = [
        Turn(id: "T001", speaker: "Ron", text: "אני עובד על ה-gateway, לחבר את ה-flow החדש ל-Kafka.", start: 44, end: 52),
        Turn(id: "T002", speaker: "Maya", text: "אז זה יהיה עם flag, לא? כן, עם flag. אני אסיים את זה עד יום חמישי.", start: 498, end: 503),
    ]

    private let notes = Notes(
        title: "Gateway sync",
        summary: "Ron moves the gateway to the new flow.",
        decisions: [Decision(text: "The new flow goes behind a flag")],
        actionItems: [ActionItem(text: "Connect the new flow to Kafka", owner: "Ron", dueDate: "2026-11-12", dueTime: "16:00", done: true)],
        openQuestions: []
    )

    private func reply(_ text: String) -> ChatReply {
        ConversationChat.reply(from: text, turns: turns, notes: notes) { _ in ("2026-11-12", nil) }
    }

    @Test func anAnswerKeepsTheQuotesThatAreInTheirTurns() {
        let reply = reply(#"{"edits": [], "evidence": [{"turn": "T001", "quote": "ה-flow החדש ל-kafka"}]}\#nAnswer: Ron is working on the new flow."#)

        #expect(reply.answer.text == "Ron is working on the new flow.")
        #expect(reply.answer.evidence == [Evidence(turn: "T001", quote: "ה-flow החדש ל-Kafka.", speaker: "Ron", start: 44)])
        #expect(reply.notes == nil && reply.edits.isEmpty)
    }

    /// The model now and then leaves a small word out of a quote, or miscopies a letter; the quote shows what was said.
    @Test func aQuoteWithASlipShowsTheTurnsWords() {
        let missing = reply(#"{"edits": [], "evidence": [{"turn": "T002", "quote": "אני אסיים זה עד יום חמישי"}]}\#nAnswer: Maya will finish it."#)
        let miscopied = reply(#"{"edits": [], "evidence": [{"turn": "T002", "quote": "כן, עם flag. אני אסיים את זה עד יום חמישו"}]}\#nAnswer: With a flag."#)

        #expect(missing.answer.evidence.map(\.quote) == ["אני אסיים את זה עד יום חמישי."])
        #expect(miscopied.answer.evidence.map(\.quote) == ["כן, עם flag. אני אסיים את זה עד יום חמישי."])
    }

    @Test func turnNumbersWrittenIntoAnAnswerAreTakenOut() {
        let text = #"{"edits": [], "evidence": [{"turn": "T001", "quote": "ה-flow החדש ל-kafka"}]}\#nAnswer: Ron is on the new flow [T001], with the old one (T001, T004) gone."#
        let pointing = #"{"edits": [], "evidence": [{"turn": "T001", "quote": "ה-flow החדש ל-kafka"}]}\#nAnswer: Ron said in [T001] that he's on the new flow."#

        #expect(reply(text).answer.text == "Ron is on the new flow, with the old one gone.")
        #expect(reply(pointing).answer.text == "Ron said that he's on the new flow.")
    }

    /// The answer isn't a JSON string, which a quotation mark the model opens would end.
    @Test func anAnswerCanQuoteAnItem() {
        let text = #"{"edits": [], "evidence": [{"item": "A1"}]}\#nAnswer: "Connect the new flow to Kafka" is Ron's,\#nand it's done."#

        #expect(reply(text).answer.text == "\"Connect the new flow to Kafka\" is Ron's,\nand it's done.")
    }

    @Test func aSecondLookChangesNothing() {
        #expect(ConversationChat.grammar.contains(#""\"change\",""#))
        #expect(!ConversationChat.answerGrammar.contains(#""\"change\",""#))
    }

    @Test(arguments: [
        // Paraphrased, not quoted.
        #"{"edits": [], "evidence": [{"turn": "T001", "quote": "הוא עובד על הזרימה"}]}\#nAnswer: Ron works on the flow."#,
        // A real quote, attributed to the wrong turn.
        #"{"edits": [], "evidence": [{"turn": "T002", "quote": "ה-flow החדש"}]}\#nAnswer: Maya works on the flow."#,
        // A confident answer with no evidence.
        #"{"edits": [], "evidence": []}\#nAnswer: The release moved to Thursday."#,
        // Words of the turn, too far apart.
        #"{"edits": [], "evidence": [{"turn": "T002", "quote": "אז flag"}]}\#nAnswer: They'll use a flag."#,
        // Too short to be anything but exact.
        #"{"edits": [], "evidence": [{"turn": "T002", "quote": "עם flog"}]}\#nAnswer: They'll use a flag."#,
        // One word proves nothing.
        #"{"edits": [], "evidence": [{"turn": "T002", "quote": "flag"}]}\#nAnswer: They'll use a flag."#,
        // Evidence, but nothing to say.
        #"{"edits": [], "evidence": [{"turn": "T002", "quote": "עם flag"}]}\#nAnswer: "#,
        // A Notes item the Notes don't have.
        #"{"edits": [], "evidence": [{"item": "A9"}]}\#nAnswer: Ron owns it."#,
        // No answer.
        #"{"edits": [], "evidence": [{"item": "A1"}]}"#,
        "not JSON",
    ])
    func withoutEvidenceThatChecksOutTheConversationDoesntSay(text: String) {
        #expect(reply(text) == ChatReply(answer: .notInConversation))
    }

    /// The answer comes from the Notes rather than from a line of the Transcript.
    @Test func aQuestionAboutTheNotesCanCiteAnItem() {
        let reply = reply(#"{"edits": [], "evidence": [{"item": "A1"}]}\#nAnswer: Ron owns it."#)

        #expect(reply.answer == Answer(text: "Ron owns it.", evidence: []))
    }

    /// Asked to add or change something, the chat writes what it's told, which no line of the Transcript says.
    @Test func aReplyThatChangesTheNotesNeedsNoQuote() throws {
        let text = #"{"edits": [{"add": "action_item", "text": "Send the report", "owner": "Maya", "due": "Thursday"}], "evidence": []}\#nAnswer: Added it."#

        let reply = reply(text)
        let added = try #require(reply.notes?.actionItems.last)

        #expect(reply.answer.text == "Added it.")
        #expect(reply.edits == [AppliedEdit(kind: .added, section: .actionItem, text: "Send the report")])
        #expect(added == ActionItem(text: "Send the report", owner: "Maya", duePhrase: "Thursday", dueDate: "2026-11-12"))
    }

    @Test func theNotesAreListedByTheirItemsNames() {
        let listing = ConversationChat.listing(notes)

        #expect(listing == """
        Title: Gateway sync
        Summary: Ron moves the gateway to the new flow.
        Decisions:
        D1. The new flow goes behind a flag
        Action items:
        A1. Connect the new flow to Kafka (owner: Ron; due: 2026-11-12 16:00; done)
        Open questions: none
        """)
    }

    /// "Thursday" in the meeting is the Thursday after it; asked for in the chat, it's the coming one.
    @Test func aDueSaidInTheConversationCountsFromItsDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        let meeting = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 11))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!

        #expect(ConversationChat.due("עד יום חמישי", saidIn: turns, on: meeting, today: today, calendar: calendar)?.date == "2026-10-22")
        #expect(ConversationChat.due("next Monday at 10am", saidIn: turns, on: meeting, today: today, calendar: calendar)?.date == "2026-11-16")
    }

    @Test(arguments: [
        ("Change its owner to Dana", ConversationLanguage.english),
        ("Thanks!", .english),
        ("Did anyone say 'בסדר'?", .english),
        ("מה ה-deadline של ה-PoC ל-Aurora?", .hebrew),
        ("PoC של Aurora מתי?", .hebrew),
        ("תוסיף שאלה פתוחה: מי אחראי על ה-QA?", .hebrew),
    ] as [(String, ConversationLanguage)])
    func aMessageIsAnsweredInItsLanguage(_ message: String, _ language: ConversationLanguage) {
        #expect(ConversationChat.language(of: message) == language)
    }

    @Test func aChatThatStartsOverIsGivenWhatTheUserSaw() {
        var flow = ChatExchange(message: "Who works on the flow?")
        flow.answer = Answer(text: "Ron.", evidence: [Evidence(turn: "T001", quote: "a b"), Evidence(turn: "T004", quote: "c d"), Evidence(turn: "T001", quote: "e f")])
        var budget = ChatExchange(message: "What's the budget?")
        budget.answer = .notInConversation
        var added = ChatExchange(message: "Add an item for Ron")
        added.answer = .notInConversation
        added.edits = [AppliedEdit(kind: .added, section: .actionItem, text: "Connect the new flow to Kafka")]
        var removed = ChatExchange(message: "Remove the flag decision")
        removed.answer = Answer(text: "Removed it.", evidence: [])
        removed.edits = [AppliedEdit(kind: .removed, section: .decision, text: "Use a flag")]
        var renamed = ChatExchange(message: "Call it the release sync")
        renamed.answer = Answer(text: "Renamed it.", evidence: [])
        renamed.edits = [AppliedEdit(kind: .title, section: nil, text: "Release sync")]
        renamed.undone = true
        var failed = ChatExchange(message: "And the date?")
        failed.failure = "The language model failed."

        let history = ConversationChat.history([flow, budget, added, removed, renamed, failed, ChatExchange(message: "Still replying?")], in: notes)

        #expect(history == """


            Earlier messages about this conversation, with the answers I was given:
            - Message: Who works on the flow?
              Answer: Ron. (T001, T004)
            - Message: What's the budget?
              Answer: The transcript doesn't say.
            - Message: Add an item for Ron
              Answer: Changed the Notes. (A1)
            - Message: Remove the flag decision
              Answer: Removed it.
            - Message: Call it the release sync
              Answer: Renamed it. I undid that change.
            """)
        #expect(ConversationChat.history([], in: notes) == "")
    }

    @Test func onlyTheLastTenMessagesAreCarriedOver() {
        let earlier = (1...12).map { number -> ChatExchange in
            var exchange = ChatExchange(message: "Question \(number)?")
            exchange.answer = .notInConversation
            return exchange
        }

        let history = ConversationChat.history(earlier, in: notes)

        #expect(!history.contains("Question 1?") && !history.contains("Question 2?"))
        #expect(history.contains("Question 3?") && history.contains("Question 12?"))
    }
}
