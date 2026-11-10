import Foundation

/// Notes as Markdown, for the clipboard and Markdown files, in the language they're written in.
public enum NotesMarkdown {
    public static func render(_ notes: Notes, startedAt: Date, endedAt: Date?) -> String {
        let language = notes.language ?? .english
        let hebrew = language == .hebrew
        var lines = ["# \(notes.title)", ""]
        lines += [when(startedAt, endedAt, in: language), "", notes.summary]

        if !notes.decisions.isEmpty {
            lines += ["", hebrew ? "## החלטות" : "## Decisions"] + notes.decisions.map { "- \($0.text)" }
        }
        if !notes.actionItems.isEmpty {
            lines += ["", hebrew ? "## משימות" : "## Action Items"] + notes.actionItems.map { item in
                let owner = item.owner.map { "**\(speaker($0, in: language))**: " } ?? ""
                let due = dueText(item, locale: locale(for: language)).map { hebrew ? " (יעד: \($0))" : " (due \($0))" } ?? ""
                return "- [\(item.done == true ? "x" : " ")] \(owner)\(item.text)\(due)"
            }
        }
        if !notes.openQuestions.isEmpty {
            lines += ["", hebrew ? "## שאלות פתוחות" : "## Open Questions"] + notes.openQuestions.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// When the Conversation was, and how long: "Thursday, Oct 22, 2026 at 14:03 · 20 min".
    static func when(_ startedAt: Date, _ endedAt: Date?, in language: ConversationLanguage = .english) -> String {
        var when = startedAt.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year().hour().minute().locale(locale(for: language)))
        if let endedAt {
            let minutes = max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
            when += language == .hebrew ? " · \(minutes) דק׳" : " · \(minutes) min"
        }
        return when
    }

    /// "Thu, Oct 22", or "Thu, Oct 22 at 16:00" with a time of day, when the due date was resolved, otherwise the
    /// spoken phrase in quotes.
    public static func dueText(_ item: ActionItem, locale: Locale = .current) -> String? {
        guard let dueDate = item.dueDate, let day = dayFormatter.date(from: dueDate) else { return item.duePhrase.map { "\"\($0)\"" } }
        guard let time = item.dueTimeOfDay, let moment = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
        }
        return moment.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(locale))
    }

    /// A Speaker's name in what Bekitzur writes in `language`, where one without a name is "Speaker 2" or "דובר 2".
    static func speaker(_ name: String, in language: ConversationLanguage) -> String {
        guard language == .hebrew else { return name }
        if name == "Speaker" { return "דובר" }
        return SpeakerLabel.number(in: name).map { "דובר \($0)" } ?? name
    }

    /// The Mac's formats in `language`'s words: its region stays, so English from a Mac set to Hebrew in Israel still
    /// writes the day before the month.
    static func locale(for language: ConversationLanguage) -> Locale {
        let current = Locale.current
        if current.language.languageCode?.identifier == language.rawValue { return current }
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(languageCode: Locale.LanguageCode(language.rawValue), region: current.region)
        return Locale(components: components)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
