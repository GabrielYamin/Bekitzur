import Foundation

/// How a Transcript reads: each Speaker's speech in lines, and the lines of people who talk at once together in a row.
public enum TranscriptRows {
    /// The words, by index, in rows of lines, each line one Speaker's words in the order they're said.
    ///
    /// A Speaker's words make a line until they pause for more than a second or someone else talks in their pause, so a
    /// reply in a pause reads as an exchange. People who talk at once for a second or more share a row, a line each in
    /// the order they start: lines whose words overlap by a second, or lines of two Speakers with words in a stretch
    /// `together` says they talked at once for a second, since speech recognition times the words of people on one input
    /// one after the other. Less than that is a reply, or one person starting as another stops: it reads as a row of its
    /// own, after the row it was said over. A line is cut where it runs into or out of such a stretch, so what one
    /// person says alone around it reads as a line of its own, but for a word or two that start or finish the sentence
    /// said at once. A row of one line right after another of the same Speaker joins it, so speech without overlaps
    /// reads as it always has.
    /// - Parameter endingSentences: The words, by index, that end a sentence (`endsSentence(_:)`).
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
        var stretches: [Stretch] = []
        for stretch in together.sorted(by: { $0.start < $1.start }) {
            let heard = stretch.end - stretch.start
            if let last = stretches.last, stretch.start - last.end < 1 {
                stretches[stretches.count - 1] = Stretch(start: last.start, end: max(last.end, stretch.end), speakers: last.speakers.union(stretch.speakers),
                                                         heard: last.heard + heard)
            } else {
                stretches.append(Stretch(start: stretch.start, end: stretch.end, speakers: stretch.speakers, heard: heard))
            }
        }
        stretches.removeAll { $0.heard < 1 }
        // A word's time can be a little off, more so when people talk at once.
        func inside(_ index: Int, _ stretch: Stretch) -> Bool {
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
        func reaches(_ line: Int, into stretch: Stretch) -> Bool {
            lines[line].contains { inside($0, stretch) }
        }
        func overlap(_ a: Int, _ b: Int) -> Bool {
            if min(spans[a].end, spans[b].end) - max(spans[a].start, spans[b].start) >= 1 { return true }
            let first = words[lines[a][0]].speaker, second = words[lines[b][0]].speaker
            guard first != second else { return false }
            return stretches.contains { stretch in
                stretch.speakers.contains(first) && stretch.speakers.contains(second) && reaches(a, into: stretch) && reaches(b, into: stretch)
            }
        }
        // A line goes with the latest row it was said at once with, so a reply said meanwhile reads after that row. A
        // row ending this long before a line starts can't be said at once with it, nor with any line after it.
        let longest: Double = stretches.map { $0.end - $0.start }.max() ?? -1.4
        var rows: [[Int]] = []
        var rowEnds: [Double] = []
        var recent: [Int] = []
        for line in lines.indices {
            recent.removeAll { rowEnds[$0] < spans[line].start - longest - 0.4 }
            if let row = recent.last(where: { row in rows[row].contains { overlap($0, line) } }) {
                rows[row].append(line)
                rowEnds[row] = max(rowEnds[row], spans[line].end)
            } else {
                recent.append(rows.count)
                rows.append([line])
                rowEnds.append(spans[line].end)
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

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]

    /// Whether a word ends a sentence, by its punctuation.
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEnds.contains(last)
    }

    /// Where the timeline heard people at once, stretches less than a second apart being one, and how long it heard
    /// them at once in all.
    private struct Stretch {
        let start: Double
        let end: Double
        let speakers: Set<String>
        let heard: Double
    }
}
