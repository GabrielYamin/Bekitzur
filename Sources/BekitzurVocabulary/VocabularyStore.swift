import BekitzurDomain
import Foundation

/// The user's Vocabulary on disk, readable only by the user.
public struct VocabularyStore: Sendable {
    public let url: URL

    public static var builtInTermCount: Int { BuiltInVocabulary.terms.count }

    /// The built-in terms and the user's own.
    public static func terms(with vocabulary: Vocabulary) -> [String] {
        BuiltInVocabulary.terms + vocabulary.terms
    }

    public init(url: URL) {
        self.url = url
    }

    /// Drops spellings of fewer than two sounds: learned before that was refused, from a word that was only a prefix
    /// (the "ב" of "ב-" in front of a project's name), they rewrote every prefix in front of an English word ("ב-GRPC"
    /// became that project's name followed by "-GRPC").
    public func load() -> Vocabulary {
        var vocabulary = (try? JSONDecoder().decode(Vocabulary.self, from: Data(contentsOf: url))) ?? Vocabulary()
        vocabulary.spellings = vocabulary.spellings.filter { Self.isSpelling($0.key) }
        return vocabulary
    }

    private static func isSpelling(_ word: String) -> Bool {
        SoundMatcher.hebrewSounds(word).count >= 2
    }

    public func save(_ vocabulary: Vocabulary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(vocabulary).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Learns from a correction: when an English term was transcribed in Hebrew letters ("הרדיס" corrected to
    /// "Redis" or "ה-Redis"), remembers the spelling without its Hebrew prefix, and the term if it's new.
    /// Returns what was learned, or nil when the correction isn't an English term for a Hebrew-letter word.
    @discardableResult
    public func learn(transcribed: String, correction: String) throws -> (spelling: String, term: String)? {
        guard let unit = SoundMatcher.unit(in: transcribed), let learned = Self.spelling(of: unit, correctedTo: correction) else { return nil }
        var vocabulary = load()
        vocabulary.spellings[learned.spelling] = learned.term
        let known = Set((BuiltInVocabulary.terms + vocabulary.terms).map { $0.lowercased() })
        if !known.contains(learned.term.lowercased()) { vocabulary.terms.append(learned.term) }
        try save(vocabulary)
        return learned
    }

    /// The spelling and term in a correction. A prefix the user kept, with or without a hyphen ("ה-Redis",
    /// "הRedis"), is taken off the spelling; otherwise the spelling is whatever part of the word sounds most like the
    /// term. A word that is only a prefix in front of English ("ב" in "ב-unbisting") teaches nothing.
    static func spelling(of unit: String, correctedTo correction: String) -> (spelling: String, term: String)? {
        let trimmed = correction.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let hebrew = String(trimmed.prefix { ("א"..."ת").contains($0) })
        let prefix: String? = hebrew.isEmpty ? nil : hebrew
        var term = String(trimmed.dropFirst(hebrew.count))
        if term.hasPrefix("-") { term.removeFirst() }
        term = term.trimmingCharacters(in: .whitespaces)
        guard prefix.map(SoundMatcher.prefixes.contains) ?? true,
              term.contains(where: { $0.isASCII && $0.isLetter }), !term.contains(where: { ("א"..."ת").contains($0) }) else { return nil }
        if let prefix, unit.hasPrefix(prefix) {
            let spelling = String(unit.dropFirst(prefix.count))
            return isSpelling(spelling) ? (spelling, term) : nil
        }
        let termSounds = SoundMatcher.englishSounds(term).map { Array($0.utf8) }
        let best = SoundMatcher.prefixes
            .filter { unit.hasPrefix($0) && unit.count - $0.count >= 2 }
            .map { prefix -> (prefix: String, distance: Int) in
                let sounds = Array(SoundMatcher.hebrewSounds(String(unit.dropFirst(prefix.count))).utf8)
                return (prefix, termSounds.map { SoundMatcher.editDistance(sounds, $0) }.min() ?? .max)
            }
            .min { ($0.distance, -$0.prefix.count) < ($1.distance, -$1.prefix.count) }
        let spelling = String(unit.dropFirst(best?.prefix.count ?? 0))
        return isSpelling(spelling) ? (spelling, term) : nil
    }
}
