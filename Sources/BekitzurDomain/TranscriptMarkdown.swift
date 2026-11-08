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

    /// - Parameter rows: A line on its own, or the lines of people who talked at once.
    public static func render(_ rows: [[Line]], title: String, startedAt: Date, endedAt: Date?) -> String {
        var lines = ["# \(title)", "", NotesMarkdown.when(startedAt, endedAt)]
        for row in rows where !row.isEmpty {
            lines.append("")
            if row.count == 1 {
                lines.append(text(row[0]))
            } else {
                lines.append("\(row.count) people at once, \(timestamp(row.map(\.start).min())):")
                lines += row.map { "- " + text($0) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ line: Line) -> String {
        "[\(timestamp(line.start))] **\(line.speaker)**: \(line.text)"
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
