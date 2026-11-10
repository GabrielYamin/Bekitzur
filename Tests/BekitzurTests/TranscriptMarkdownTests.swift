import BekitzurDomain
import Foundation
import Testing

/// The Transcript as Markdown, for the clipboard.
struct TranscriptMarkdownTests {
    @Test func linesComeWithWhoSaidThemAndWhenAndPeopleAtOnceTogether() {
        let rows: [TranscriptMarkdown.Row] = [
            .init(lines: [.init(speaker: "Gabriel", start: 149, text: "אני שנייה רוצה רק לשאול שאלה.")]),
            .init(lines: [.init(speaker: "Eli", start: 158.2, text: "מבחינת גם שמות,"), .init(speaker: "Gabriel", start: 162.3, text: "ואני כן רוצה לחדד")], atOnce: 161.1),
            .init(lines: [.init(speaker: "Speaker 3", start: 3_725, text: "Thanks, bye.")]),
        ]

        let text = TranscriptMarkdown.render(rows, title: "Planning", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1_200))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "# Planning")
        #expect(lines[2].hasSuffix(" · 20 min"))
        #expect(Array(lines[3...]) == [
            "",
            "[2:29] **Gabriel**: אני שנייה רוצה רק לשאול שאלה.",
            "",
            "2 people at once, 2:41:",
            "- [2:38] **Eli**: מבחינת גם שמות,",
            "- [2:42] **Gabriel**: ואני כן רוצה לחדד",
            "",
            "[1:02:05] **Speaker 3**: Thanks, bye.",
            "",
        ])
    }

    /// Copied from a Conversation whose Notes are in Hebrew, its own words are Hebrew too.
    @Test func withHebrewNotesItsOwnWordsAreHebrew() {
        let rows: [TranscriptMarkdown.Row] = [
            .init(lines: [.init(speaker: "Speaker 2", start: 5, text: "מתחילים?")]),
            .init(lines: [.init(speaker: "Dana", start: 38, text: "כן,"), .init(speaker: "Speaker 2", start: 41, text: "רגע")], atOnce: 40),
        ]

        let text = TranscriptMarkdown.render(
            rows, title: "תכנון", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1_200), language: .hebrew
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[2].hasSuffix(" · 20 דק׳"))
        #expect(Array(lines[3...]) == [
            "",
            "[0:05] **דובר 2**: מתחילים?",
            "",
            "2 אנשים בבת אחת, 0:40:",
            "- [0:38] **Dana**: כן,",
            "- [0:41] **דובר 2**: רגע",
            "",
        ])
    }
}
