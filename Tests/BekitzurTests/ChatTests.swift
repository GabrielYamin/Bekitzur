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

    @Test func earlierTurnsAreInGemmasFormat() {
        let prompt = LanguageModel.gemma4Prompt(system: "S", turns: ["U1", "M1", "U2"])

        #expect(prompt == "<|turn>system\nS<turn|>\n<|turn>user\nU1<turn|>\n<|turn>model\n<|channel>thought\n<channel|>M1<turn|>\n<|turn>user\nU2<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
    }

    /// The last exchange comes back as it went, with the Notes the chat saw then, so "remove it" points where it did.
    @Test func aChatThatStartsOverIsGivenItsLastReplyAsItsOwn() {
        var question = ChatExchange(message: "Who works on the flow?")
        question.answer = Answer(text: "Ron.", evidence: [Evidence(turn: "T001", quote: "a b")])
        question.reply = "{}\nAnswer: Ron."
        let added = addingAnItem()
        let listing = ConversationChat.listing(notes)
        let request = ConversationChat.request("Add an item for Maya", notesIn: .english)
        let first = """
            TRANSCRIPT

            The Notes Bekitzur wrote from it:
            \(listing)

            Earlier messages about this conversation, with the answers I was given:
            - Message: Who works on the flow?
              Answer: Ron. (T001)

            \(request)
            """

        let after = ConversationChat.listing(added.notesAfter!)

        let opening = ConversationChat.opening("TRANSCRIPT", notes: added.notesAfter!, after: [question, added], request: "Message: Remove it")

        #expect(opening == [first, added.reply!, "The Notes now:\n\(after)\n\nYour last reply changed A2.\n\nMessage: Remove it"])
    }

    @Test func whatTheLastReplyLeftDifferentComesWithTheNextMessage() {
        var undone = addingAnItem()
        undone.undone = true
        var unanswered = ChatExchange(message: "Who decides?")
        unanswered.answer = .notInConversation
        unanswered.reply = "{}\nAnswer:"
        let listing = ConversationChat.listing(notes)

        let afterUndo = ConversationChat.opening("TRANSCRIPT", notes: notes, after: [undone], request: "Message: Add it back")
        let afterNothing = ConversationChat.opening("TRANSCRIPT", notes: notes, after: [unanswered], request: "Message: And Ron?")

        #expect(afterUndo.last == "The Notes now:\n\(listing)\n\nMessage: Add it back")
        #expect(afterNothing.last == "\(ConversationChat.notFoundNote)\n\nMessage: And Ron?")
    }

    @Test func theNextMessageSaysWhatTheLastReplyChanged() {
        let edits = [
            AppliedEdit(kind: .changed, section: .actionItem, text: "Connect the new flow to Kafka"),
            AppliedEdit(kind: .removed, section: .decision, text: "The new flow goes behind a flag"),
            AppliedEdit(kind: .summary, section: nil, text: "Ron connects the flow."),
        ]

        #expect(ConversationChat.lastChange(edits, in: notes) == "Your last reply changed A1, the summary.\n\n")
        #expect(ConversationChat.lastChange([edits[1]], in: notes) == "")
    }

    private let theirs = Notes(
        title: "Release sync",
        summary: "The release moves to Thursday.",
        decisions: [Decision(text: "Release on Thursday")],
        actionItems: [ActionItem(text: "Tell support about the release", owner: "Dana")],
        openQuestions: []
    )
    /// Monday, 2 November 2026, at noon in UTC, which is the same day in Israel.
    private let released = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!

    private var reference: ChatReference {
        ChatReference(ChatCandidate(id: "2026-11-02-120000", title: "Release sync", date: released, people: ["Dana", "Ron"]), notes: theirs)
    }

    @Test func anotherConversationsItemsHaveNamesNoEditCanUse() {
        #expect(ConversationChat.brought(reference) == """
            The Notes of another conversation, "Release sync" on Monday, 2 November 2026, with Dana, Ron:
            Title: Release sync
            Summary: The release moves to Thursday.
            Decisions:
            OD1. Release on Thursday
            Action items:
            OA1. Tell support about the release (owner: Dana)
            Open questions: none
            """)
        #expect(ConversationChat.grammar.contains(#"noted ::= "{" ws "\"item\":" ws (item | theiritem) ws "}""#))
        #expect(ConversationChat.grammar.contains(#"change ::= "{" ws "\"change\":" ws item ","#))
    }

    @Test func aMessageAboutAnotherConversationPicksItFromTheList() {
        let candidates = [
            ChatCandidate(id: "b", title: "Release sync", date: released, people: ["Dana", "Ron"]),
            ChatCandidate(id: "a", title: "Kickoff", date: released.addingTimeInterval(-7 * 86_400), people: []),
        ]
        let today = released.addingTimeInterval(9 * 86_400)
        let this = released.addingTimeInterval(-14 * 86_400)
        let lookup = "{\n  \"asks\": \"another conversation\",\n  \"conversation\": \"C2\"\n}"

        #expect(ConversationChat.choices(candidates, today: today, this: this, with: ["Ron", "Maya"]) == """
            This conversation is from Monday, 19 October 2026, with Ron, Maya.
            The user's other recorded conversations, newest first; today is Wednesday, 11 November 2026:
            C1. Monday, 2 November 2026: "Release sync", with Dana, Ron
            C2. Monday, 26 October 2026: "Kickoff"
            """)
        #expect(ConversationChat.asksAboutAnother(lookup) && ConversationChat.picked(lookup) == 2)
        #expect(!ConversationChat.asksAboutAnother(#"{"asks": "question", "edits": [], "evidence": []}\#nAnswer: Ron."#))
        #expect(ConversationChat.picked(#"{"asks": "another conversation", "conversation": null}"#) == nil)
        #expect(ConversationChat.lookupGrammar.contains(#""\"another conversation\"," ws "\"conversation\":""#))
        #expect(!ConversationChat.grammar.contains("another conversation"))
    }

    @Test func theOtherConversationsAreListedAfterTheNotes() {
        let candidates = [ChatCandidate(id: "b", title: "Release sync", date: released, people: ["Dana", "Ron"])]
        let today = released.addingTimeInterval(9 * 86_400)
        let listing = ConversationChat.listing(notes)
        let choices = ConversationChat.choices(candidates, today: today, this: released, with: ["Ron", "Maya"])

        let opening = ConversationChat.opening("TRANSCRIPT", notes: notes, after: [], request: "Message: Hi", listing: choices)

        #expect(opening == ["TRANSCRIPT\n\nThe Notes Bekitzur wrote from it:\n\(listing)\n\n\(choices)\n\nMessage: Hi"])
    }

    /// A follow-up about the other Conversation brought in for the message before stands on its Notes, still in the chat.
    @Test func aReplyCitingTheNotesBroughtInIsFromThem() {
        let byName = #"{"asks": "question", "edits": [], "evidence": [{"item": "OA1"}]}\#nAnswer: Dana."#
        let byQuote = #"{"asks": "question", "edits": [], "evidence": [{"turn": "T001", "quote": "Tell support about the release"}]}\#nAnswer: Dana."#
        let fromHere = #"{"asks": "question", "edits": [], "evidence": [{"item": "A1"}]}\#nAnswer: Ron."#

        #expect(ConversationChat.cites(byName, from: theirs))
        #expect(ConversationChat.cites(byQuote, from: theirs))
        #expect(!ConversationChat.cites(fromHere, from: theirs))
    }

    /// An answer can stand on the other Conversation's Notes: items it has, cited by name or quoted as if a turn.
    @Test func anAnswerCanStandOnAnotherConversationsNotes() {
        let text = #"{"edits": [], "evidence": [{"item": "OA1"}]}\#nAnswer: Dana tells support."#
        let quoted = #"{"edits": [], "evidence": [{"turn": "T002", "quote": "OA1. Tell support about the release (owner: Dana)"}]}\#nAnswer: Dana."#
        let missing = #"{"edits": [], "evidence": [{"item": "OA2"}]}\#nAnswer: Ron tells support."#
        let restated = #"{"edits": [], "evidence": []}\#nAnswer: Nothing was decided; Dana is to tell support about the release."#

        let answered = ConversationChat.reply(from: text, turns: turns, notes: notes, other: theirs) { _ in nil }
        let fromAQuote = ConversationChat.reply(from: quoted, turns: turns, notes: notes, other: theirs) { _ in nil }
        let fromTheAnswer = ConversationChat.reply(from: restated, turns: turns, notes: notes, other: theirs) { _ in nil }
        let alone = ConversationChat.reply(from: text, turns: turns, notes: notes) { _ in nil }
        let restatedAlone = ConversationChat.reply(from: restated, turns: turns, notes: notes) { _ in nil }
        let invented = ConversationChat.reply(from: missing, turns: turns, notes: notes, other: theirs) { _ in nil }

        #expect(answered.answer.text == "Dana tells support.")
        #expect(fromAQuote.answer.text == "Dana.")
        #expect(fromTheAnswer.answer.text == "Nothing was decided; Dana is to tell support about the release.")
        #expect(ConversationChat.cites(restated, from: theirs))
        #expect(alone == ChatReply(answer: .notInConversation))
        #expect(restatedAlone == ChatReply(answer: .notInConversation))
        #expect(invented == ChatReply(answer: .notInConversation))
    }

    @Test func aChatThatStartsOverHasTheOtherConversationItUsed() {
        var asked = ChatExchange(message: "What did we decide at the release sync?")
        asked.answer = Answer(text: "To release on Thursday.", evidence: [])
        asked.reply = #"{"asks": "question", "edits": [], "evidence": [{"item": "OD1"}]}"# + "\nAnswer: To release on Thursday."
        asked.reference = reference
        let brought = ConversationChat.brought(reference)
        let request = ConversationChat.request(asked.message, notesIn: .english)

        let opening = ConversationChat.opening("TRANSCRIPT", notes: notes, after: [asked], request: "Message: And who tells support?")
        let history = ConversationChat.history([asked], in: notes)

        #expect(opening.count == 3)
        #expect(opening.first?.hasSuffix("\(brought)\n\n\(request)") == true)
        #expect(opening.last == "Message: And who tells support?")
        #expect(history.hasSuffix("Answer: To release on Thursday. From the Notes of \"Release sync\" on Monday, 2 November 2026."))
    }

    /// A chat saved before replies were kept is given its earlier messages as a list.
    @Test func withoutTheLastReplyTheEarlierMessagesAreListed() {
        var old = ChatExchange(message: "Who works on the flow?")
        old.answer = Answer(text: "Ron.", evidence: [])

        let opening = ConversationChat.opening("TRANSCRIPT", notes: notes, after: [old], request: "Message: And Maya?")

        #expect(opening.count == 1)
        #expect(opening.first?.hasSuffix("- Message: Who works on the flow?\n  Answer: Ron.\n\nMessage: And Maya?") == true)
    }

    private func addingAnItem() -> ChatExchange {
        let (changed, applied) = notes.applying([.add(.actionItem, text: "Send the report", owner: "Maya", due: nil)]) { _ in nil }
        var exchange = ChatExchange(message: "Add an item for Maya")
        exchange.answer = Answer(text: "Added an action item for Maya to send the report.", evidence: [])
        exchange.edits = applied
        exchange.notesBefore = notes
        exchange.notesAfter = changed
        exchange.reply = #"{"asks": "change", "edits": [{"add": "action_item", "text": "Send the report", "owner": "Maya", "due": null}], "evidence": []}"#
            + "\nAnswer: Added an action item for Maya to send the report."
        return exchange
    }
}
