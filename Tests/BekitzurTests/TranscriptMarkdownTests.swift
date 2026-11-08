import BekitzurDomain
import Foundation
import Testing

/// The Transcript as Markdown, for the clipboard.
struct TranscriptMarkdownTests {
    @Test func linesComeWithWhoSaidThemAndWhenAndPeopleAtOnceTogether() {
        let rows: [[TranscriptMarkdown.Line]] = [
            [.init(speaker: "Gabriel", start: 149, text: "אני שנייה רוצה רק לשאול שאלה.")],
            [.init(speaker: "Eli", start: 161.1, text: "מבחינת גם שמות,"), .init(speaker: "Gabriel", start: 162.3, text: "ואני כן רוצה לחדד")],
            [.init(speaker: "Speaker 3", start: 3_725, text: "Thanks, bye.")],
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
            "- [2:41] **Eli**: מבחינת גם שמות,",
            "- [2:42] **Gabriel**: ואני כן רוצה לחדד",
            "",
            "[1:02:05] **Speaker 3**: Thanks, bye.",
            "",
        ])
    }
}
