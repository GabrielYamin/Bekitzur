import BekitzurDomain
import BekitzurNotes
import Foundation

/// Rewrites English terms that the Transcript spells in Hebrew letters into English letters ("רדיס" → "Redis").
///
/// A spelling the user taught Bekitzur is applied as is. Any other word that sounds like a Vocabulary term goes to the
/// language model with the text around it, which picks one of the matched terms or rejects them; it can never propose
/// a term of its own. A rewritten word keeps what was transcribed in `transcribed`.
public struct VocabularyRewriter {
    public struct Candidate: Sendable {
        public let unit: String
        public let matches: [SoundMatcher.Match]
        public let context: String

        public init(unit: String, matches: [SoundMatcher.Match], context: String) {
            self.unit = unit
            self.matches = matches
            self.context = context
        }
    }

    public struct Report: Sendable {
        public var learned = 0
        public var verified = 0
        public var rejected = 0
        public var failedBatches = 0
        public var promptTokens = 0
        public var outputTokens = 0

        public init() {}
    }

    private let matcher: SoundMatcher
    private let spellings: [String: String]
    private let verify: ([Candidate], inout Report) -> [String: SoundMatcher.Match]

    public init(vocabulary: Vocabulary, model: LanguageModel) {
        let verifier = TermVerifier(model: model)
        self.init(vocabulary: vocabulary) { verifier.choose($0, report: &$1) }
    }

    init(vocabulary: Vocabulary, verify: @escaping ([Candidate], inout Report) -> [String: SoundMatcher.Match]) {
        matcher = SoundMatcher(terms: BuiltInVocabulary.terms + vocabulary.terms)
        spellings = vocabulary.spellings
        self.verify = verify
    }

    /// Starts from what was transcribed, so spellings and terms taught or removed since an earlier rewrite apply to
    /// every word, not only to words still in Hebrew letters.
    public func rewrite(_ transcript: Transcript) -> (Transcript, Report) {
        let transcript = Self.asTranscribed(transcript)
        var report = Report()
        let text = transcript.segments.flatMap { $0.words?.map(\.text) ?? [$0.text] }.joined(separator: " ")
        var replacements: [String: SoundMatcher.Match] = [:]
        var candidates: [Candidate] = []
        var unitOfWord: [String: String] = [:]
        var seen = Set<String>()
        for word in transcript.segments.flatMap({ $0.words ?? [] }) where unitOfWord[word.text] == nil {
            // A hyphenated pair that sounds like nothing may still hold a term in one of its words.
            var unit = SoundMatcher.token(in: word.text)
            var matches: [SoundMatcher.Match] = []
            if let pair = SoundMatcher.pair(in: word.text), learnedMatch(pair) != nil || !matcher.matches(pair).isEmpty {
                unit = pair
            }
            guard let unit else { continue }
            unitOfWord[word.text] = unit
            guard seen.insert(unit).inserted else { continue }
            if let learned = learnedMatch(unit) {
                replacements[unit] = learned
                report.learned += 1
                continue
            }
            matches = matcher.matches(unit)
            if !matches.isEmpty {
                candidates.append(Candidate(unit: unit, matches: matches, context: Self.context(of: word.text, in: text)))
            }
        }
        if !candidates.isEmpty {
            let chosen = verify(candidates, &report)
            report.verified += chosen.count
            report.rejected += candidates.count - chosen.count
            replacements.merge(chosen.map { ($0.key, Self.inflected($0.value, unit: $0.key)) }) { learned, _ in learned }
        }
        guard !replacements.isEmpty else { return (transcript, report) }

        var result = transcript
        for s in result.segments.indices {
            guard var words = result.segments[s].words else { continue }
            var changed = false
            for w in words.indices {
                guard let unit = unitOfWord[words[w].text], let match = replacements[unit],
                      let range = words[w].text.range(of: unit) else { continue }
                words[w].transcribed = words[w].text
                words[w].text.replaceSubrange(range, with: match.replacement)
                changed = true
            }
            if changed {
                result.segments[s].words = words
                result.segments[s].text = words.map(\.text).joined(separator: " ")
            }
        }
        return (result, report)
    }

    /// The language model's pick for each word from its own matches; words it rejects are left out.
    public func choose(_ candidates: [Candidate], report: inout Report) -> [String: SoundMatcher.Match] {
        verify(candidates, &report)
    }

    static func asTranscribed(_ transcript: Transcript) -> Transcript {
        var result = transcript
        for s in result.segments.indices {
            guard var words = result.segments[s].words, words.contains(where: { $0.transcribed != nil }) else { continue }
            for w in words.indices {
                guard let transcribed = words[w].transcribed else { continue }
                words[w].text = transcribed
                words[w].transcribed = nil
            }
            result.segments[s].words = words
            result.segments[s].text = words.map(\.text).joined(separator: " ")
        }
        return result
    }

    /// The term in the plural when the Hebrew word is, so a rewrite doesn't drop it: a Hebrew plural ending
    /// ("פרטישנים") or an English one spelled ס ("קליינטס"), unless the term itself ends in an s sound ("סרוויס").
    public static func inflected(_ match: SoundMatcher.Match, unit: String) -> SoundMatcher.Match {
        let rest = unit.dropFirst(match.prefix.count)
        let hebrewPlural = rest.hasSuffix("ים") || rest.hasSuffix("ות")
        let englishPlural = rest.hasSuffix("ס") && !SoundMatcher.englishSounds(match.term).contains { $0.hasSuffix("S") }
        let term = match.term.lowercased()
        let alreadyPlural = term.hasSuffix("s") && !["ss", "us", "is"].contains { term.hasSuffix($0) }
        guard hebrewPlural || englishPlural, !alreadyPlural, match.term.last?.isLetter == true else { return match }
        let ending = ["s", "x", "z", "sh", "ch"].contains { term.hasSuffix($0) } ? "es" : "s"
        return SoundMatcher.Match(prefix: match.prefix, term: match.term + ending)
    }

    /// A spelling the user taught, with or without a Hebrew prefix in front of it.
    private func learnedMatch(_ unit: String) -> SoundMatcher.Match? {
        for prefix in SoundMatcher.prefixes.sorted(by: { $0.count < $1.count }) where unit.hasPrefix(prefix) {
            if let term = spellings[String(unit.dropFirst(prefix.count))] { return SoundMatcher.Match(prefix: prefix, term: term) }
        }
        return nil
    }

    /// About 60 characters on each side of the word's first appearance, cut back to whole words.
    public static func context(of word: String, in text: String, width: Int = 60) -> String {
        guard let range = text.range(of: word) else { return word }
        let start = text.index(range.lowerBound, offsetBy: -width, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        var window = Substring(text[start..<end])
        if start != text.startIndex, let space = window.firstIndex(of: " ") { window = window[window.index(after: space)...] }
        if end != text.endIndex, let space = window.lastIndex(of: " ") { window = window[..<space] }
        return window.trimmingCharacters(in: .whitespaces)
    }
}

/// Asks the language model which of each word's matched terms it is, if any.
///
/// The model answers every item, "none" included: asked to list only the terms, it missed clear terms and let
/// ordinary words through (scripted read: 43 of 72 terms in English letters instead of 56). Each answer is keyed by its
/// item's id, which the grammar puts in order, and may only be "none" or that item's own candidates, so the model can't
/// put a term on a word that doesn't sound like it. Repeating each Hebrew word made the answers four times longer; with
/// no key at all, answers slid onto neighboring items (in a 32-minute meeting: "ראשונה" as "version", "קפקא" left as is).
struct TermVerifier {
    let model: LanguageModel

    static let instructions = """
        Each item has an id, one or two Hebrew words from a speech transcript of an Israeli tech meeting, the text around \
        them, and candidate English terms. If an item's Hebrew words are one of its candidates spelled in Hebrew letters \
        (possibly with a Hebrew prefix such as ה or ל), its answer is that candidate exactly. If they are ordinary Hebrew \
        words or none of the candidates, its answer is none. Answer with a JSON object mapping each item's id to its answer.
        """

    private struct Item: Encodable {
        let id: Int
        let hebrew_word: String
        let context: String
        let candidates: [String]
    }

    /// {"0": …, "1": …} with each item's id in order, and for each "none" or one of its candidates.
    static func grammar(for candidates: ArraySlice<VocabularyRewriter.Candidate>) -> String {
        let start = candidates.startIndex
        let answers = candidates.indices.map { #""\"\#($0 - start)\"" ws ":" ws a\#($0)"# }
        var rules = [#"root ::= "{" ws "# + answers.joined(separator: #" ws "," ws "#) + #" ws "}""#]
        for (index, candidate) in zip(candidates.indices, candidates) {
            let options = ["none"] + candidate.matches.map(\.term)
            rules.append("a\(index) ::= " + options.map { #""\""# + literal($0) + #"\"""# }.joined(separator: " | "))
        }
        rules.append(#"ws ::= [ \t\n]{0,20}"#)
        return rules.joined(separator: "\n")
    }

    private static func literal(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\\\\\"")
    }

    /// Small batches with only nearby text, so a request can't overflow the context.
    func choose(_ candidates: [VocabularyRewriter.Candidate], report: inout VocabularyRewriter.Report, batch: Int = 20) -> [String: SoundMatcher.Match] {
        var chosen: [String: SoundMatcher.Match] = [:]
        for start in stride(from: 0, to: candidates.count, by: batch) {
            let slice = candidates[start..<min(start + batch, candidates.count)]
            let items = slice.indices.map { Item(id: $0 - start, hebrew_word: candidates[$0].unit, context: candidates[$0].context, candidates: candidates[$0].matches.map(\.term)) }
            do {
                let user = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
                let completion = try model.complete(system: Self.instructions, user: user, grammar: Self.grammar(for: slice), maxTokens: 1_024)
                report.promptTokens += completion.promptTokens
                report.outputTokens += completion.outputTokens
                let answers = try JSONDecoder().decode([String: String].self, from: Data(completion.text.utf8))
                guard answers.count == slice.count else { throw VerifierError.wrongCount }
                for (index, candidate) in zip(slice.indices, slice) {
                    if let answer = answers[String(index - start)], let match = candidate.matches.first(where: { $0.term == answer }) {
                        chosen[candidate.unit] = match
                    }
                }
            } catch {
                report.failedBatches += 1
            }
        }
        return chosen
    }

    private enum VerifierError: Error {
        case wrongCount
    }
}
