import BekitzurDomain
import SwiftUI

/// The Transcript as lyrics: the line being played large, with who's saying it and its words lit as they're said, the
/// two before it fading above and the next ones below. Clicking a line plays from it.
struct LyricsView: View {
    let rows: [TranscriptRow]
    /// For a line without letters to tell its direction by.
    let fallback: TextDirection
    let playback: PlaybackModel
    let play: (Double) -> Void

    var body: some View {
        let current = Self.row(at: playback.time, in: rows)
        let first = max(0, (current ?? 0) - 2)
        let last = min(rows.count, (current ?? -1) + 4)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows[first..<last]) { row in
                if row.id == current {
                    ForEach(row.lines) { line in
                        CurrentLyric(line: line, time: playback.time, rightToLeft: rightToLeft(line))
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(row.lines) { line in
                        Lyric(line: line, past: current.map { row.id < $0 } ?? false, rightToLeft: rightToLeft(line))
                            .onTapGesture { play(line.start) }
                    }
                }
            }
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: current)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing was said", systemImage: "waveform")
            }
        }
    }

    private func rightToLeft(_ line: TranscriptLine) -> Bool {
        line.text.direction(fallback: fallback) == .rightToLeft
    }

    /// The row whose start playback last passed, which stays while nobody talks; nil before the first one.
    static func row(at time: Double, in rows: [TranscriptRow]) -> Int? {
        var low = 0, high = rows.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if rows[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found.map { rows[$0].id }
    }
}

/// A line before or after the one being played: small, with a small avatar, fainter the further back it is.
private struct Lyric: View {
    let line: TranscriptLine
    let past: Bool
    let rightToLeft: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PersonAvatar(name: line.speaker, size: 16)
                .opacity(past ? 0.45 : 0.8)
            Text(line.text)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(past ? .quaternary : .tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        .help("Play from here")
    }
}

/// The line being played: who's saying it and when, and its words, the ones said so far lit.
private struct CurrentLyric: View {
    let line: TranscriptLine
    let time: Double
    let rightToLeft: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                PersonAvatar(name: line.speaker, size: 20)
                Text(ShownNames.speaker(line.speaker)).fontWeight(.semibold)
                Text(timestamp(line.start)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(sung)
                .font(.system(size: 23, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }

    /// The words said by `time` in the text's color, and the rest fainter; a line without word times all lit.
    private var sung: AttributedString {
        guard !line.words.isEmpty else { return AttributedString(line.text) }
        let said = line.words.filter { $0.word.start <= time }.map(\.text).filter { !$0.isEmpty }
        let rest = line.words.filter { $0.word.start > time }.map(\.text).filter { !$0.isEmpty }
        var text = AttributedString(said.joined(separator: " "))
        text.foregroundColor = .primary
        var waiting = AttributedString((said.isEmpty || rest.isEmpty ? "" : " ") + rest.joined(separator: " "))
        waiting.foregroundColor = .secondary
        return text + waiting
    }
}
