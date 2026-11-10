import Foundation

/// A Transcript as Markdown, for the clipboard: its lines as the Transcript shows them, each with who said it and when,
/// and the lines of people who talked at once together.
public enum TranscriptMarkdown {
    /// One Speaker's speech, as shown.
    public struct Line: Sendable, Equatable {
        public let speaker: String
        public let start: Double
        public let text: String

        public init(speaker: String, start: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.text = text
        }
    }

    /// A line on its own, or the lines of people who talked at once.
    public struct Row: Sendable, Equatable {
        public let lines: [Line]
        /// When a second person starts talking.
        public let atOnce: Double?

        public init(lines: [Line], atOnce: Double? = nil) {
            self.lines = lines
            self.atOnce = atOnce
        }
    }

    /// - Parameter language: The language of the Conversation's Notes, which give it its title, so its own words match.
    public static func render(_ rows: [Row], title: String, startedAt: Date, endedAt: Date?, language: ConversationLanguage = .english) -> String {
        var lines = ["# \(title)", "", NotesMarkdown.when(startedAt, endedAt, in: language)]
        for row in rows where !row.lines.isEmpty {
            lines.append("")
            if row.lines.count == 1 {
                lines.append(text(row.lines[0], in: language))
            } else {
                let at = timestamp(row.atOnce ?? row.lines.map(\.start).min())
                lines.append(language == .hebrew ? "\(row.lines.count) אנשים בבת אחת, \(at):" : "\(row.lines.count) people at once, \(at):")
                lines += row.lines.map { "- " + text($0, in: language) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ line: Line, in language: ConversationLanguage) -> String {
        "[\(timestamp(line.start))] **\(NotesMarkdown.speaker(line.speaker, in: language))**: \(line.text)"
    }
}

/// A moment of a Recording as the app writes it: 1:05, or 1:02:05 past an hour.
public func timestamp(_ seconds: Double?) -> String {
    guard let seconds else { return "" }
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
