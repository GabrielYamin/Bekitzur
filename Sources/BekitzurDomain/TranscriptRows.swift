import Foundation

/// How a Transcript reads: each Speaker's speech in lines, and the lines of people who talk at once together in a row.
public enum TranscriptRows {
    /// The words, by index, in rows of lines, each line one Speaker's words in the order they're said.
    ///
    /// A Speaker's words make a line until they pause for more than a second or someone else talks in their pause, so a
    /// reply in a pause reads as an exchange. Lines that overlap by 0.4 seconds, or a short line by half its length, go
    /// in one row, a line per Speaker in the order they start. A row of one line right after another of the same
    /// Speaker joins it, so speech without overlaps reads as it always has.
    public static func layout(_ words: [(start: Double, end: Double, speaker: String)]) -> [[[Int]]] {
        // A word's last token can be timed seconds late, and a word can be timed as taking no time at all.
        func end(_ index: Int) -> Double { min(max(words[index].end, words[index].start + 0.2), words[index].start + 0.6) }
        let order = words.indices.sorted { (words[$0].start, $0) < (words[$1].start, $1) }
        var open: [String: (line: [Int], position: Int)] = [:]
        var lines: [[Int]] = []
        for (position, index) in order.enumerated() {
            let word = words[index]
            if let current = open[word.speaker], let last = current.line.last {
                let someoneInThePause = order[(current.position + 1)..<position].contains { other in
                    words[other].speaker != word.speaker && words[other].start >= end(last) - 0.05 && end(other) <= word.start + 0.05
                }
                if word.start - end(last) > 1 || someoneInThePause {
                    lines.append(current.line)
                    open[word.speaker] = nil
                }
            }
            open[word.speaker, default: ([], position)].line.append(index)
            open[word.speaker]?.position = position
        }
        lines += open.values.map(\.line)
        lines.sort { (words[$0[0]].start, $0[0]) < (words[$1[0]].start, $1[0]) }

        let spans = lines.map { line in (start: words[line[0]].start, end: line.map(end).max() ?? words[line[0]].start) }
        func overlap(_ a: Int, _ b: Int) -> Bool {
            let shared = min(spans[a].end, spans[b].end) - max(spans[a].start, spans[b].start)
            let shorter = min(spans[a].end - spans[a].start, spans[b].end - spans[b].start)
            return shared > 0 && shared >= min(0.4, shorter / 2)
        }
        var rows: [[Int]] = []
        for line in lines.indices {
            if let row = rows.last, row.contains(where: { overlap($0, line) }) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        var result: [[[Int]]] = []
        for row in rows {
            var bySpeaker: [String: [Int]] = [:]
            var speakers: [String] = []
            for line in row {
                let speaker = words[lines[line][0]].speaker
                if bySpeaker[speaker] == nil { speakers.append(speaker) }
                bySpeaker[speaker, default: []] += lines[line]
            }
            let joined = speakers.map { bySpeaker[$0, default: []].sorted { (words[$0].start, $0) < (words[$1].start, $1) } }
            if joined.count == 1, let last = result.last, last.count == 1, words[last[0][0]].speaker == speakers[0] {
                result[result.count - 1][0] += joined[0]
            } else {
                result.append(joined)
            }
        }
        return result
    }
}
