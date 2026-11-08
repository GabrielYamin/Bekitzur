import Foundation

/// Notes as Markdown, for the clipboard and Markdown files.
public enum NotesMarkdown {
    public static func render(_ notes: Notes, startedAt: Date, endedAt: Date?) -> String {
        var lines = ["# \(notes.title)", ""]
        lines += [when(startedAt, endedAt), "", notes.summary]

        if !notes.decisions.isEmpty {
            lines += ["", "## Decisions"] + notes.decisions.map { "- \($0.text)" }
        }
        if !notes.actionItems.isEmpty {
            lines += ["", "## Action Items"] + notes.actionItems.map { item in
                let owner = item.owner.map { "**\($0)**: " } ?? ""
                let due = dueText(item).map { " (due \($0))" } ?? ""
                return "- [\(item.done == true ? "x" : " ")] \(owner)\(item.text)\(due)"
            }
        }
        if !notes.openQuestions.isEmpty {
            lines += ["", "## Open Questions"] + notes.openQuestions.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// When the Conversation was, and how long: "Thursday, Oct 22, 2026 at 14:03 · 20 min".
    static func when(_ startedAt: Date, _ endedAt: Date?) -> String {
        var when = startedAt.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year().hour().minute())
        if let endedAt {
            when += " · \(max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))) min"
        }
        return when
    }

    /// "Thu, Oct 22" when the due date was resolved, otherwise the spoken phrase in quotes.
    public static func dueText(_ item: ActionItem) -> String? {
        if let dueDate = item.dueDate, let date = dayFormatter.date(from: dueDate) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return item.duePhrase.map { "\"\($0)\"" }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
