import Foundation

/// How a Transcript reads: each Speaker's speech in lines, and the lines of people who talk at once together in a row.
public enum TranscriptRows {
    /// The words, by index, in rows of lines, each line one Speaker's words in the order they're said.
    ///
    /// A Speaker's words make a line until they pause for more than a second or someone else talks in their pause, so a
    /// reply in a pause reads as an exchange. Lines that overlap by 0.4 seconds, or a short line by half its length, go
    /// in one row, a line per Speaker in the order they start, as do lines of two Speakers with words in a stretch
    /// `together` says they talked at once: speech recognition times the words of people who talk at once one after the
    /// other. A line is cut where it runs into or out of such a stretch, so what one person says alone around it reads as
    /// a line of its own, but for a word or two that start or finish the sentence said at once. A row of one line right
    /// after another of the same Speaker joins it, so speech without overlaps reads as it always has.
    /// - Parameter endingSentences: The words, by index, that end a sentence.
    public static func layout(
        _ words: [(start: Double, end: Double, speaker: String)],
        together: [(start: Double, end: Double, speakers: Set<String>)] = [],
        endingSentences: Set<Int> = []
    ) -> [[[Int]]] {
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

        // Stretches less than a second apart are one, so a short pause between them doesn't cut a sentence.
        var stretches: [(start: Double, end: Double, speakers: Set<String>)] = []
        for stretch in together.sorted(by: { $0.start < $1.start }) {
            if let last = stretches.last, stretch.start - last.end < 1 {
                stretches[stretches.count - 1] = (last.start, max(last.end, stretch.end), last.speakers.union(stretch.speakers))
            } else {
                stretches.append(stretch)
            }
        }
        // A word's time can be a little off, more so when people talk at once.
        func inside(_ index: Int, _ stretch: (start: Double, end: Double, speakers: Set<String>)) -> Bool {
            words[index].start >= stretch.start - 0.2 && words[index].start <= stretch.end + 0.2
        }
        for stretch in stretches {
            lines = lines.flatMap { line -> [[Int]] in
                guard stretch.speakers.contains(words[line[0]].speaker) else { return [line] }
                var before = line.filter { words[$0].start < stretch.start - 0.2 }
                var after = line.filter { words[$0].start > stretch.end + 0.2 }
                var within = line.filter { inside($0, stretch) }
                // A word or two on their own would read as a line cut short.
                if before.count <= 2, let last = before.last, !endingSentences.contains(last) {
                    within = before + within
                    before = []
                }
                if after.count <= 2, let last = within.last, !endingSentences.contains(last) {
                    within += after
                    after = []
                }
                return [before, within, after].filter { !$0.isEmpty }
            }
        }
        lines.sort { (words[$0[0]].start, $0[0]) < (words[$1[0]].start, $1[0]) }

        let spans = lines.map { line in (start: words[line[0]].start, end: line.map(end).max() ?? words[line[0]].start) }
        func reaches(_ line: Int, into stretch: (start: Double, end: Double, speakers: Set<String>)) -> Bool {
            lines[line].contains { inside($0, stretch) }
        }
        func overlap(_ a: Int, _ b: Int) -> Bool {
            let shared = min(spans[a].end, spans[b].end) - max(spans[a].start, spans[b].start)
            let shorter = min(spans[a].end - spans[a].start, spans[b].end - spans[b].start)
            if shared > 0, shared >= min(0.4, shorter / 2) { return true }
            let first = words[lines[a][0]].speaker, second = words[lines[b][0]].speaker
            guard first != second else { return false }
            return stretches.contains { stretch in
                stretch.speakers.contains(first) && stretch.speakers.contains(second) && reaches(a, into: stretch) && reaches(b, into: stretch)
            }
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
