/// Which way text runs, for lines that mix Hebrew and English.
public enum TextDirection: Sendable, Equatable {
    case leftToRight, rightToLeft

    public var opposite: TextDirection {
        self == .leftToRight ? .rightToLeft : .leftToRight
    }

    /// The direction of a word's first and last letters; nil for a word without letters, like a number.
    public static func ends(of word: some StringProtocol) -> (first: TextDirection, last: TextDirection)? {
        let letters = word.unicodeScalars.filter(\.properties.isAlphabetic)
        guard let first = letters.first, let last = letters.last else { return nil }
        return (direction(of: first), direction(of: last))
    }

    /// The direction of most of a line's words, each by its first letter, so "ה-deployment" counts as Hebrew; on a tie,
    /// the direction of the line's first letter, and with no letters, `fallback`.
    public static func of(_ words: [some StringProtocol], fallback: TextDirection) -> TextDirection {
        let firsts = words.compactMap { ends(of: $0)?.first }
        let rightToLeft = firsts.filter { $0 == .rightToLeft }.count
        let leftToRight = firsts.count - rightToLeft
        if rightToLeft != leftToRight { return rightToLeft > leftToRight ? .rightToLeft : .leftToRight }
        return firsts.first ?? fallback
    }

    /// For each word of a line, the run of words in the other direction it belongs to, numbered from 0, or nil when it
    /// follows the line. Two words are in a run when the first ends, and the next starts, with a letter in the other
    /// direction, so "ה-code review" in Hebrew is one English run; a word without letters joins the run around it. A
    /// single word is no run: its own letters are laid out by the text system.
    public static func runs(_ words: [some StringProtocol], in direction: TextDirection) -> [Int?] {
        let other = direction.opposite
        let wordEnds = words.map { ends(of: $0) }
        // A word without letters takes the direction of the words on both sides when they agree with each other.
        let resolved: [(first: TextDirection, last: TextDirection)] = wordEnds.indices.map { index in
            if let known = wordEnds[index] { return known }
            let before = wordEnds[..<index].compactMap { $0 }.last?.last
            let after = wordEnds[(index + 1)...].compactMap { $0 }.first?.first
            let side = before == other && after == other ? other : direction
            return (side, side)
        }
        var runs = [Int?](repeating: nil, count: words.count)
        var next = 0
        var start = 0
        while start < words.count {
            var end = start
            while end + 1 < words.count, resolved[end].last == other, resolved[end + 1].first == other { end += 1 }
            if end > start {
                for index in start...end { runs[index] = next }
                next += 1
            }
            start = end + 1
        }
        return runs
    }

    /// The order in which to place a line's words from its starting edge, the right one for a right-to-left line: words
    /// in their order, but each run in the other direction reversed, so it reads in its own direction.
    public static func placement(_ runs: [Int?]) -> [Int] {
        var order: [Int] = []
        var index = 0
        while index < runs.count {
            guard let run = runs[index] else {
                order.append(index)
                index += 1
                continue
            }
            var end = index
            while end + 1 < runs.count, runs[end + 1] == run { end += 1 }
            order += (index...end).reversed()
            index = end + 1
        }
        return order
    }

    static func direction(of letter: Unicode.Scalar) -> TextDirection {
        (0x0590...0x08FF).contains(letter.value) || (0xFB1D...0xFEFF).contains(letter.value) ? .rightToLeft : .leftToRight
    }
}
