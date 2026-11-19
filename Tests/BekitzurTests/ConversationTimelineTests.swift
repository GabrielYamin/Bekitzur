import Foundation
import Testing
@testable import BekitzurDomain

struct ConversationTimelineTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text)
    }

    /// A lane joins words a short pause apart into one stretch and starts another after a long one; Speakers come in
    /// the order they first talk, and a segment without word times is a stretch of its own.
    @Test func eachSpeakerHasALaneOfStretches() {
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 0, end: 3, text: "מעלים את 2.4", speaker: "Ron", words: [word("מעלים", 0, 1), word("את", 1.2, 1.5), word("2.4", 2, 3)]),
            TranscriptSegment(start: 3.5, end: 5, text: "ביום חמישי", speaker: "Dana", words: [word("ביום", 3.5, 4), word("חמישי", 4.2, 5)]),
            TranscriptSegment(start: 9, end: 10, text: "אחרי הרגרסיה", speaker: "Ron", words: [word("אחרי", 9, 9.5), word("הרגרסיה", 9.6, 10)]),
            TranscriptSegment(start: 12, end: 14, text: "סגור", speaker: "Speaker 3"),
        ])

        let timeline = ConversationTimeline(transcript: transcript, notes: Notes(), turns: [], yourNotes: [])

        #expect(timeline.lanes.map(\.speaker) == ["Ron", "Dana", "Speaker 3"])
        #expect(timeline.lanes[0].stretches == [0...3, 9...10])
        #expect(timeline.lanes[1].stretches == [3.5...5])
        #expect(timeline.lanes[2].stretches == [12...14])
        #expect(timeline.length == 14)
    }

    /// Each item is where its first Source starts, one a note made without Sources is where the note was written, and
    /// one with neither isn't on the timeline; the Recording's length counts when it's longer than what's in it.
    @Test func itemsAreWhereTheyWereSaidAndNotesWhereTheyWereWritten() {
        let note = UserNote(at: 40, text: "[ ] send Maya the deck")
        let turns = [Turn(id: "T001", speaker: "Ron", text: "", start: 10, end: 12), Turn(id: "T002", speaker: "Dana", text: "", start: 20, end: 25)]
        var made = ActionItem(text: "Send Maya the deck")
        made.fromYourNote = note.id
        let written = Notes(
            title: "Release",
            summary: "",
            decisions: [Decision(text: "Ship 2.4 on Thursday", sourceTurns: ["T002", "T001"])],
            actionItems: [ActionItem(text: "Check the payment flow", sourceTurns: ["T002"]), made, ActionItem(text: "Tell support")],
            openQuestions: [OpenQuestion(text: "Who runs the release?", sourceTurns: ["T001"])]
        )

        let timeline = ConversationTimeline(
            transcript: Transcript(language: .hebrew, segments: []),
            notes: written,
            turns: turns,
            yourNotes: [note, UserNote(at: 5, text: " ")],
            length: 60
        )

        #expect(timeline.items == [
            ConversationTimeline.Item(kind: .decision, index: 0, at: 10),
            ConversationTimeline.Item(kind: .openQuestion, index: 0, at: 10),
            ConversationTimeline.Item(kind: .actionItem, index: 0, at: 20),
            ConversationTimeline.Item(kind: .actionItem, index: 1, at: 40),
        ])
        #expect(timeline.yourNotes.map(\.id) == [note.id])
        #expect(timeline.length == 60)
    }
}
