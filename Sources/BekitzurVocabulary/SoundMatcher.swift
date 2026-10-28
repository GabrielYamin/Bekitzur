import Foundation

/// Finds the Vocabulary terms a Hebrew-letter word sounds like.
///
/// ivrit.ai's model writes most English terms in Hebrew letters ("רדיס" for Redis). Both spellings are reduced to
/// consonant sounds and compared, allowing one difference in longer terms. Loose matching, meant to be checked by the
/// verifier, also accepts two-sound terms. A hyphenated word pair (the model hyphenates terms it splits, און-קול)
/// must match exactly, since two ordinary words joined together often land near some term.
public struct SoundMatcher: Sendable {
    public struct Match: Hashable, Sendable {
        /// A Hebrew prefix kept in front of the term, like ה in ה-gateway.
        public let prefix: String
        public let term: String

        /// How the word is written once matched: "ה-gateway", or the bare term.
        public var replacement: String { prefix.isEmpty ? term : "\(prefix)-\(term)" }
    }

    static let prefixes = ["", "ה", "ו", "ב", "ל", "מ", "ש", "כ", "וה", "שה", "כשה", "מה", "וב", "ול", "ומ", "וש", "כש", "שב", "שמ"]

    private static let hebrewSound: [Character: Character] = [
        "ב": "B", "ג": "G", "ד": "D", "ה": "H", "ז": "S", "ח": "H", "ט": "T", "כ": "K", "ל": "L",
        "מ": "M", "נ": "N", "ס": "S", "פ": "P", "צ": "S", "ק": "K", "ר": "R", "ש": "X", "ת": "T",
    ]

    /// Letter groups first, in this order; c and g depend on the next letter; vowels make no sound.
    private static let englishRules: [(letters: [Character], sounds: [String])] = [
        ("tion", ["XN"]), ("sion", ["XN"]), ("sch", ["SK", "X"]), ("sh", ["X"]), ("ch", ["C", "K"]), ("ph", ["P"]),
        ("th", ["T"]), ("ck", ["K"]), ("qu", ["KB", "K"]), ("x", ["KS"]), ("q", ["K"]), ("w", ["B", ""]), ("y", [""]),
        ("h", ["H", ""]), ("j", ["J"]), ("f", ["P"]), ("v", ["B"]), ("z", ["S"]), ("s", ["S"]), ("b", ["B"]),
        ("p", ["P"]), ("k", ["K"]), ("d", ["D"]), ("t", ["T"]), ("l", ["L"]), ("m", ["M"]), ("n", ["N"]), ("r", ["R"]),
    ].map { (Array($0.0), $0.1) }

    private struct Entry: Sendable {
        let term: String
        let sounds: [UInt8]
    }

    private let entriesByLength: [Int: [Entry]]
    private let shortest: Int
    private let fuzzyFrom: Int

    public init(terms: [String], loose: Bool = true) {
        shortest = loose ? 2 : 3
        fuzzyFrom = loose ? 4 : 5
        var byLength: [Int: [Entry]] = [:]
        for term in Set(terms) {
            for sounds in Self.englishSounds(term) where sounds.count >= shortest {
                byLength[sounds.count, default: []].append(Entry(term: term, sounds: Array(sounds.utf8)))
            }
        }
        entriesByLength = byLength
    }

    /// Every (prefix, term) the word sounds like at the closest distance, or none. On a tie the longest prefix wins, so
    /// a real conjunction or article (ו, ה) isn't dropped.
    public func matches(_ unit: String) -> [Match] {
        let fuzzyFrom = unit.contains("-") ? Int.max : self.fuzzyFrom
        var hits: [(distance: Int, prefixLength: Int, match: Match)] = []
        for prefix in Self.prefixes where unit.hasPrefix(prefix) && unit.count - prefix.count >= 2 {
            let rest = String(unit.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "")
            let sounds = Array(Self.hebrewSounds(rest).utf8)
            guard sounds.count >= shortest else { continue }
            for length in (sounds.count - 1)...(sounds.count + 1) {
                for entry in entriesByLength[length] ?? [] {
                    let allowed = entry.sounds.count >= fuzzyFrom ? 1 : 0
                    guard abs(entry.sounds.count - sounds.count) <= allowed else { continue }
                    let distance = Self.editDistance(sounds, entry.sounds)
                    if distance <= allowed {
                        hits.append((distance, prefix.count, Match(prefix: prefix, term: entry.term)))
                    }
                }
            }
        }
        guard let best = hits.min(by: { ($0.distance, -$0.prefixLength) < ($1.distance, -$1.prefixLength) }) else { return [] }
        return Set(hits.filter { $0.distance == best.distance && $0.prefixLength == best.prefixLength }.map(\.match))
            .sorted { ($0.prefix, $0.term) < ($1.prefix, $1.term) }
    }

    /// The part of a word that can be an English term spelled in Hebrew letters: a hyphenated pair of Hebrew words, or
    /// the word's Hebrew letters without surrounding punctuation.
    public static func unit(in word: String) -> String? {
        pair(in: word) ?? token(in: word)
    }

    public static func pair(in word: String) -> String? {
        word.firstMatch(of: /[א-ת][א-ת'׳"״]*-[א-ת][א-ת'׳"״]*/).map { String($0.output) }
    }

    public static func token(in word: String) -> String? {
        word.firstMatch(of: /[א-ת][א-ת'׳"״]*/).map { String($0.output) }
    }

    static func hebrewSounds(_ word: String) -> String {
        var w = word
        for (final, regular) in zip(["ך", "ם", "ן", "ף", "ץ"], ["כ", "מ", "נ", "פ", "צ"]) {
            w = w.replacingOccurrences(of: final, with: regular)
        }
        w = w.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "״", with: "")
        for (letter, sound) in [("ג", "J"), ("צ", "C"), ("ז", "J")] {
            for geresh in ["'", "׳"] { w = w.replacingOccurrences(of: letter + geresh, with: sound) }
        }
        w = w.replacingOccurrences(of: "וו", with: "B")
        if w.hasSuffix("ה") { w.removeLast() }
        return String(w.compactMap { "JCB".contains($0) ? $0 : hebrewSound[$0] })
    }

    static func englishSounds(_ term: String) -> Set<String> {
        var variants = [""]
        for word in term.lowercased().split(whereSeparator: { !("a"..."z").contains($0) }) {
            let letters = collapsingPairs(Array(word))
            var options = [""]
            var i = 0
            while i < letters.count {
                let sounds: [String]
                let step: Int
                if let rule = englishRules.first(where: { $0.letters.count > 1 && letters[i...].starts(with: $0.letters) }) {
                    (sounds, step) = (rule.sounds, rule.letters.count)
                } else if letters[i] == "c" || letters[i] == "g" {
                    let soft = i + 1 < letters.count && "eiy".contains(letters[i + 1])
                    sounds = letters[i] == "c" ? (soft ? ["S", "K"] : ["K"]) : (soft ? ["J", "G"] : ["G"])
                    step = 1
                } else {
                    sounds = englishRules.first { $0.letters == [letters[i]] }?.sounds ?? [""]
                    step = 1
                }
                options = Array(options.flatMap { option in sounds.map { option + $0 } }.prefix(64))
                i += step
            }
            variants = Array(variants.flatMap { variant in options.map { variant + $0 } }.prefix(64))
        }
        return Set(variants)
    }

    /// "letter" → "leter": a doubled letter is one sound.
    private static func collapsingPairs(_ letters: [Character]) -> [Character] {
        var result: [Character] = []
        var i = 0
        while i < letters.count {
            result.append(letters[i])
            i += i + 1 < letters.count && letters[i] == letters[i + 1] ? 2 : 1
        }
        return result
    }

    static func editDistance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
