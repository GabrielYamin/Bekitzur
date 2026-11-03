import Foundation
import Testing
@testable import BekitzurDomain

struct ConversationTests {
    private func conversation() -> ProcessedConversation {
        ProcessedConversation(
            transcript: Transcript(language: .hebrew, segments: [
                TranscriptSegment(start: 0, end: 2, text: "נעלה היום", speaker: "Speaker 1"),
                TranscriptSegment(start: 2, end: 4, text: "אני אבדוק", speaker: "Speaker 10"),
            ]),
            speakers: [
                ConversationSpeaker(label: "Speaker 1", speechSeconds: 2, embedding: [1, 0], naming: .unknown),
                ConversationSpeaker(label: "Speaker 10", speechSeconds: 2, embedding: [0, 1], naming: .suggested("Yossi", similarity: 0.5)),
            ],
            turns: [
                Turn(id: "T001", speaker: "Speaker 1", text: "נעלה היום", start: 0, end: 2),
                Turn(id: "T002", speaker: "Speaker 10", text: "אני אבדוק", start: 2, end: 4),
            ],
            notes: Notes(
                title: "Release plan with Speaker 1",
                summary: "Speaker 1 ships today; Speaker 10 reviews. Speaker 1's fix is ready.",
                decisions: [Decision(text: "Speaker 1 owns the release", sourceTurns: ["T001"], quote: "נעלה היום")],
                actionItems: [
                    ActionItem(text: "Ship the fix", owner: "Speaker 1", duePhrase: "היום", dueDate: "2026-10-18", sourceTurns: ["T001"], quote: "נעלה היום"),
                    ActionItem(text: "Review what Speaker 1 shipped", owner: "Speaker 10", duePhrase: nil, dueDate: nil, sourceTurns: ["T002"], quote: "אני אבדוק"),
                ],
                openQuestions: [OpenQuestion(text: "Will Speaker 1 need help?", sourceTurns: ["T001"])]
            )
        )
    }

    @Test func renamingASpeakerUpdatesEverythingTheyAppearIn() {
        let renamed = conversation().renamingSpeaker("Speaker 1", to: "Dana")

        #expect(renamed.speakers[0].naming == .named("Dana", similarity: 1))
        #expect(renamed.transcript.segments.map(\.speaker) == ["Dana", "Speaker 10"])
        #expect(renamed.turns.map(\.speaker) == ["Dana", "Speaker 10"])
        #expect(renamed.notes.title == "Release plan with Dana")
        #expect(renamed.notes.summary == "Dana ships today; Speaker 10 reviews. Dana's fix is ready.")
        #expect(renamed.notes.decisions[0].text == "Dana owns the release")
        #expect(renamed.notes.actionItems.map(\.owner) == ["Dana", "Speaker 10"])
        #expect(renamed.notes.actionItems[1].text == "Review what Dana shipped")
        #expect(renamed.notes.openQuestions[0].text == "Will Dana need help?")
    }

    @Test func renamingAnAutoNamedSpeakerReplacesTheWrongName() {
        let named = conversation().renamingSpeaker("Speaker 10", to: "Yossi")
        let corrected = named.renamingSpeaker("Speaker 10", to: "Avi")

        #expect(corrected.notes.actionItems[1].owner == "Avi")
        #expect(corrected.notes.summary.contains("Avi reviews"))
        #expect(corrected.notes.summary.contains("Speaker 1 ships"))
    }

    /// A two-person discussion: "זה על" opens the user's answer, and "גייטוויי" was transcribed for "gateway".
    @Test func marksMoveWordsToTheirSpeakerAndCorrectTheirText() {
        let words = [("על", 5.76), ("המק?", 5.99), ("זה", 6.24), ("על", 6.42)].map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let reply = [("המק,", 6.62), ("גייטוויי", 7.0)].map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 5.7, end: 6.5, text: "על המק? זה על", speaker: "Speaker 1", words: words),
            TranscriptSegment(start: 6.6, end: 7.1, text: "המק, גייטוויי", speaker: "Omer", words: reply),
        ])
        var flags = TranscriptFlags()
        flags.assign(words[2], to: "Omer", transcribedAs: "Speaker 1")
        flags.assign(words[3], to: "Omer", transcribedAs: "Speaker 1")
        flags.correct(reply[1], as: "gateway")

        let corrected = transcript.applying(flags)

        #expect(corrected.segments.map(\.speaker) == ["Speaker 1", "Omer", "Omer"])
        #expect(corrected.segments.map(\.text) == ["על המק?", "זה על", "המק, gateway"])
        #expect(transcript.applying(TranscriptFlags()) == transcript)
    }

    @Test func aWordMarkedAsSaidBySomeoneElseGoesToTheOtherOfTwoSpeakers() {
        let word = TranscriptWord(start: 1, end: 1, text: "כלום")
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 0, end: 1, text: "כלום", speaker: "Speaker 1", words: [word]),
            TranscriptSegment(start: 2, end: 3, text: "זה", speaker: "Omer", words: [TranscriptWord(start: 2, end: 2, text: "זה")]),
        ])
        var flags = TranscriptFlags()
        flags.words = [TranscriptFlags.Word(start: 1, text: "כלום", otherSpeaker: true)]

        #expect(transcript.applying(flags).segments.map(\.speaker) == ["Omer", "Omer"])
    }

    @Test func notesMarkdownHasTheDefaultSections() {
        let notes = conversation().notes
        let started = ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z")!
        let markdown = NotesMarkdown.render(notes, startedAt: started, endedAt: started.addingTimeInterval(32 * 60))

        #expect(markdown.hasPrefix("# Release plan with Speaker 1\n"))
        #expect(markdown.contains("· 32 min"))
        #expect(markdown.contains("## Decisions\n- Speaker 1 owns the release"))
        #expect(markdown.contains("- [ ] **Speaker 1**: Ship the fix (due "))
        #expect(markdown.contains("- [ ] **Speaker 10**: Review what Speaker 1 shipped\n"))
        #expect(markdown.contains("## Open Questions\n- Will Speaker 1 need help?"))
    }

    /// A build from before October 28 wrote null as text for each of a meeting's five Action Items, which showed as a due
    /// date of "null", in the Notes and in a Conversation imported from it.
    @Test func nullWrittenAsTextIsNoOwnerOrDueDate() throws {
        let fromTheModel = #"{"text": "Send the report", "owner": "null", "due_phrase": " NULL ", "source_turns": ["T001"], "quote": "אשלח"}"#
        let saved = #"{"text": "Fix the build", "owner": "Speaker 1", "duePhrase": "null", "sourceTurns": [], "quote": ""}"#
        let said = #"{"text": "Ship it", "owner": "", "duePhrase": "by Friday", "sourceTurns": [], "quote": ""}"#
        let model = JSONDecoder()
        model.keyDecodingStrategy = .convertFromSnakeCase

        let first = try model.decode(ActionItem.self, from: Data(fromTheModel.utf8))
        let second = try JSONDecoder().decode(ActionItem.self, from: Data(saved.utf8))
        let third = try JSONDecoder().decode(ActionItem.self, from: Data(said.utf8))

        #expect(first.owner == nil && first.duePhrase == nil && first.sourceTurns == ["T001"])
        #expect(second.owner == "Speaker 1" && second.duePhrase == nil)
        #expect(third.owner == nil && third.duePhrase == "by Friday")
        #expect(try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(second)) == second)
    }
}
