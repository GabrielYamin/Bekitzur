import Foundation

/// Finding text in a Transcript the way a find bar does: ignoring case and accents (niqqud too), inside words and across
/// them.
public enum TranscriptSearch {
    /// Each place `query` appears in the words read in order with a space between them, as the words it covers, by
    /// index, in order. A word the query appears in more than once counts once.
    public static func matches(of query: String, in words: [String]) -> [ClosedRange<Int>] {
        let query = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !query.isEmpty else { return [] }
        var starts: [Int] = []
        var offset = 0
        for word in words {
            starts.append(offset)
            offset += word.utf16.count + 1
        }
        let text = words.joined(separator: " ") as NSString
        func word(at location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= location { low = middle } else { high = middle - 1 }
            }
            return low
        }
        var matches: [ClosedRange<Int>] = []
        var location = 0
        while location < text.length {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            let covered = word(at: found.location)...word(at: found.location + max(found.length, 1) - 1)
            if matches.last != covered { matches.append(covered) }
            location = found.location + max(found.length, 1)
        }
        return matches
    }
}
