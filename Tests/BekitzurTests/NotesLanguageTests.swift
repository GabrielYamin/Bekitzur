import Foundation
import Testing
@testable import BekitzurDomain
@testable import BekitzurNotes

/// Notes in the language chosen for them, whatever language the Conversation is in, and copied in it.
struct NotesLanguageTests {
    private let notes = Notes(
        title: "תכנון השחרור",
        summary: "Speaker 1 משחרר היום.",
        decisions: [Decision(text: "משחררים היום", sourceTurns: ["T001"], quote: "אני משחרר היום")],
        actionItems: [
            ActionItem(text: "לשחרר את התיקון", owner: "Speaker 1", duePhrase: "היום", dueDate: "2026-10-18", sourceTurns: ["T001"], quote: "אני משחרר היום"),
            ActionItem(text: "לבדוק את מה ששוחרר", owner: "Dana", sourceTurns: ["T002"], quote: "אני אבדוק אחרי"),
        ],
        openQuestions: [OpenQuestion(text: "האם צריך עזרה?", sourceTurns: ["T001"])]
    )

    @Test func englishNotesAreAskedForAsBefore() {
        let instructions = NotesWriter.instructions(writingIn: .english)

        #expect(instructions.contains("Write the Notes in English, even when the conversation is in Hebrew"))
        #expect(!instructions.contains("Write the Notes in Hebrew"))
    }

    /// Renaming a Speaker looks for their label in the Notes, so Hebrew Notes keep it as the transcript writes it; and
    /// told only to write in Hebrew, the model left out commitments.
    @Test func hebrewNotesKeepTheTranscriptsNamesAndLabelsAndEveryItem() {
        let instructions = NotesWriter.instructions(writingIn: .hebrew)

        #expect(instructions.contains("Write the Notes in Hebrew, even when the conversation is in English"))
        #expect(instructions.contains(#"an unnamed speaker's label exactly as it is, like "Speaker 2""#))
        #expect(instructions.contains("Hebrew changes only the words"))
        #expect(instructions.contains("Extract:"))
    }

    @Test func theCheckAsksForItemsInTheNotesLanguage() {
        let items = NotesWriter.reviewItems(notes)
        let english = NotesWriter.reviewRequest(items)
        let hebrew = NotesWriter.reviewRequest(items, in: .hebrew)

        #expect(english.contains(#"says "it", "this", "that", or the like"#))
        #expect(english.contains("Every item is in English."))
        #expect(hebrew.contains(#"says "זה", "את זה", "הדבר הזה", or the like"#))
        #expect(hebrew.contains("Every item is in Hebrew."))
    }

    /// Notes saved before they could be in Hebrew have no language, which is English.
    @Test func notesRememberTheLanguageTheyreWrittenIn() throws {
        var written = notes
        written.language = .hebrew

        #expect(try JSONDecoder().decode(Notes.self, from: JSONEncoder().encode(written)).language == .hebrew)
        let before = #"{"title": "Sync", "summary": "", "decisions": [], "actionItems": [], "openQuestions": []}"#
        #expect(try JSONDecoder().decode(Notes.self, from: Data(before.utf8)).language == nil)
    }

    @Test func hebrewNotesAreCopiedInHebrew() {
        var hebrew = notes
        hebrew.language = .hebrew
        let started = ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z")!

        let markdown = NotesMarkdown.render(hebrew, startedAt: started, endedAt: started.addingTimeInterval(32 * 60))

        #expect(markdown.hasPrefix("# תכנון השחרור\n"))
        #expect(markdown.contains("· 32 דק׳"))
        #expect(markdown.contains("## החלטות\n- משחררים היום\n"))
        #expect(markdown.contains("## משימות\n- [ ] **דובר 1**: לשחרר את התיקון (יעד: "))
        #expect(markdown.contains("- [ ] **Dana**: לבדוק את מה ששוחרר\n"))
        #expect(markdown.contains("## שאלות פתוחות\n- האם צריך עזרה?\n"))
        #expect(NotesMarkdown.render(notes, startedAt: started, endedAt: nil).contains("## Action Items\n- [ ] **Speaker 1**: "))
    }

    @Test func aSpeakerWithoutANameIsNumberedInEitherLanguage() {
        #expect(SpeakerLabel.number(in: SpeakerLabel.label(12)) == 12)
        #expect(SpeakerLabel.number(in: "Dana") == nil)
        #expect(SpeakerLabel.number(in: "Speaker") == nil)
        #expect(NotesMarkdown.speaker("Speaker 3", in: .hebrew) == "דובר 3")
        #expect(NotesMarkdown.speaker("Speaker 3", in: .english) == "Speaker 3")
        #expect(NotesMarkdown.speaker("Dana", in: .hebrew) == "Dana")
    }
}
