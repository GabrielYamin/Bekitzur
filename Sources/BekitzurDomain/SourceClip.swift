import Foundation

/// What a Source plays in place: the words its item quotes, from a little before them. They're looked for in the turn,
/// then in the whole Transcript, since separating people who talked at once and fixes move words after the Notes are
/// written, and the model can cite a turn next to the quote's. For a quote found nowhere, or none, it's the start of the
/// turn, at most half a minute.
public struct SourceClip: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let quoted: Bool
    }

    public let range: ClosedRange<Double>
    /// Who said the words, as the Transcript has it now.
    public let speaker: String?
    /// Their words in the clip, the quoted ones marked.
    public let words: [Word]

    /// From before the quote, which can be the question it answers.
    static let lead = 2.0
    static let tail = 0.5
    static let longest = 30.0
    /// How far a turn known only by its start is searched for the quote.
    static let reach = 120.0

    private struct Spoken {
        let word: TranscriptWord
        let speaker: String?
    }

    /// - Parameters:
    ///   - speaker: The turn's, as the Transcript names it.
    ///   - end: The turn's; nil for one known only by its start.
    /// - Returns: Nil for a turn without a start.
    public init?(quote: String?, speaker: String, start: Double?, end: Double?, in transcript: Transcript) {
        guard let start else { return nil }
        var spoken: [Spoken] = []
        for segment in transcript.segments {
            for word in segment.words ?? [] { spoken.append(Spoken(word: word, speaker: segment.speaker)) }
        }
        spoken.sort { $0.word.start < $1.word.start }
        let last = end ?? start + Self.reach
        let turn = spoken.indices.filter { index in
            let word = spoken[index]
            return word.speaker == speaker && word.word.start >= start - 0.05 && word.word.start <= last + 0.05
        }
        let quote = Self.tokens(quote ?? "")
        // In the turn, a quote the model worded a little differently; elsewhere, only a close one.
        let found = Self.find(quote, among: turn, of: spoken, near: start, matching: 0.5)
            ?? Self.find(quote, among: Array(spoken.indices), of: spoken, near: start, matching: 0.6)
        var shown: [Word] = []
        if let found {
            let who = spoken[found.lowerBound].speaker
            let from = max(0, spoken[found.lowerBound].word.start - Self.lead)
            range = from...(spoken[found.upperBound].word.end + Self.tail)
            self.speaker = who
            // A word starting in the tail is cut off as it starts.
            for index in spoken.indices where index <= found.upperBound && spoken[index].speaker == who && range.contains(spoken[index].word.start) {
                shown.append(Word(text: spoken[index].word.text, quoted: found.contains(index)))
            }
        } else {
            var upper = min(start + Self.longest, end ?? .infinity)
            if let lastWord = turn.last { upper = min(upper, spoken[lastWord].word.end) }
            range = start...max(upper, start + 1)
            self.speaker = speaker
            for index in turn where spoken[index].word.start < range.upperBound {
                shown.append(Word(text: spoken[index].word.text, quoted: false))
            }
        }
        self.words = shown
    }

    /// Words as compared: lowercase, without punctuation, so "Okay," finds "okay".
    static func tokens(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// The first and last of `candidates` that say the quote: all its words in a row, or else the stretch of its length
    /// where most of them match, at least two and `matching` of them. Of equal ones, the nearest `time`.
    private static func find(_ quote: [String], among candidates: [Int], of spoken: [Spoken], near time: Double, matching: Double) -> ClosedRange<Int>? {
        var tokens: [String] = [], owner: [Int] = []
        for index in candidates {
            for token in Self.tokens(spoken[index].word.text) {
                tokens.append(token)
                owner.append(index)
            }
        }
        guard !quote.isEmpty, tokens.count >= quote.count else { return nil }
        var best: (start: Int, matches: Int, distance: Double)?
        for start in 0...(tokens.count - quote.count) {
            var matches = 0
            for offset in quote.indices where quote[offset] == tokens[start + offset] { matches += 1 }
            let distance = abs(spoken[owner[start]].word.start - time)
            if let best, matches < best.matches || (matches == best.matches && distance >= best.distance) { continue }
            best = (start, matches, distance)
        }
        guard let best else { return nil }
        let enough = best.matches == quote.count || (best.matches >= 2 && Double(best.matches) >= matching * Double(quote.count))
        return enough ? owner[best.start]...owner[best.start + quote.count - 1] : nil
    }
}
