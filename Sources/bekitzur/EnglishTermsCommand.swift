import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurNotes
import BekitzurPipeline
import BekitzurTranscription
import BekitzurVocabulary
import Foundation

struct EnglishTermsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "english-terms",
        abstract: """
            Experiment: English terms proposed by the Vocabulary and by a second run forced to English, competing terms \
            narrowed by the audio, and the language model deciding. Taught spellings aren't applied.
            """
    )

    @Argument(help: "Audio file.")
    var audio: String

    @Argument(help: "Engine Transcript JSON of the Hebrew run, from transcribe --json without --speakers.")
    var transcript: String

    @Option(help: "Engine Transcript JSON of the same audio from plain Whisper with --language en; its words become candidates.")
    var english: String?

    @Option(help: "Vocabulary file.")
    var vocabulary: String = BekitzurPaths.vocabulary.path

    @Option(parsing: .upToNextOption, help: "Terms to leave out of the Vocabulary.")
    var without: [String] = []

    @Flag(help: "Take no candidates from the Vocabulary's terms.")
    var noList = false

    @Option(help: "With two or more terms for a word, drop those the audio scores this far below the best; 0 skips the audio.")
    var audioMargin: Double = 0

    @Option(help: "Speech model for the audio scores.")
    var scoringModel: String = BekitzurPaths.speechModel(for: .hebrew).path

    @Option(help: """
        Word list that the English run's words must be in, or be Vocabulary terms; only lowercase entries count, which \
        leaves out names. Empty to take every word.
        """)
    var dictionary: String = "/usr/share/dict/words"

    @Option(help: "Write the rewritten text, one segment per line, to this file.")
    var out: String

    @Option(help: "Write each word's candidates and the decision as JSON to this file.")
    var decisions: String?

    /// Words the English run writes for ordinary speech; they'd match Hebrew words by sound without being terms.
    private static let commonWords = Set("""
        a about after again all also am an and any are as at be because been before being but by can could did do does \
        doing done down each even every few for from get gets getting go goes going gone good got had has have having he \
        her here him his how i if in into is it its just know let like made make many may me more most much must my need \
        no not now of off ok okay on once one only or other our out over own really right said same say see she should so \
        some still such take than that the their them then there these they thing think this those through time to too two \
        under up us very want was way we well were what when where which while who why will with would yes yet you your
        """.split(separator: " ").map(String.init))

    struct Place {
        let segment: Int
        let word: Int
    }

    struct Proposal: Codable {
        let replacement: String
        var sources: [String]
        var audio: Double?
        var kept = true
    }

    struct Decision: Codable {
        let unit: String
        let occurrences: Int
        let proposals: [Proposal]
        let chosen: String?
    }

    func run() async throws {
        let started = Date()
        let hebrew = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(filePath: transcript)))
        let heard = try english.map { try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(filePath: $0))) }
        let leftOut = Set(without.map { $0.lowercased() })
        let vocabulary = VocabularyStore(url: URL(filePath: self.vocabulary)).load()
        let terms = VocabularyStore.terms(with: vocabulary).filter { !leftOut.contains($0.lowercased()) }
        let listMatcher = SoundMatcher(terms: noList ? [] : terms)
        let known: Set<String>? = dictionary.isEmpty ? nil : Set(
            try String(contentsOfFile: dictionary, encoding: .utf8).split(separator: "\n")
                .filter { $0.first?.isLowercase == true }.map(String.init) + terms.map { $0.lowercased() }
        )
        let englishWords = (heard.map(Self.englishWords) ?? []).filter { heardWord in
            known.map { Self.isWord(heardWord.word, in: $0) } ?? true
        }
        let words = hebrew.segments.map { $0.words ?? [] }

        func unit(of word: String) -> String? {
            guard let token = SoundMatcher.token(in: word) else { return nil }
            if let pair = SoundMatcher.pair(in: word), !listMatcher.matches(pair).isEmpty { return pair }
            return token
        }

        // Each unit's places and proposals, in order of first appearance; proposals are keyed by their replacement.
        var order: [String] = []
        var places: [String: [Place]] = [:]
        var options: [String: [String: (match: SoundMatcher.Match, sources: Set<String>)]] = [:]
        func propose(_ match: SoundMatcher.Match, from source: String, for unit: String) {
            let key = match.replacement.lowercased()
            if options[unit]?[key] != nil {
                options[unit]![key]!.sources.insert(source)
            } else {
                options[unit, default: [:]][key] = (match, [source])
            }
        }
        for (s, segmentWords) in words.enumerated() {
            for (w, word) in segmentWords.enumerated() {
                guard let unit = unit(of: word.text) else { continue }
                if places[unit] == nil {
                    order.append(unit)
                    listMatcher.matches(unit).forEach { propose($0, from: "list", for: unit) }
                }
                places[unit, default: []].append(Place(segment: s, word: w))
                let near = englishWords.filter { $0.start - 3 <= word.start && word.start <= $0.end + 3 }.map(\.word)
                if !near.isEmpty {
                    SoundMatcher(terms: near).matches(unit).forEach { propose($0, from: "english", for: unit) }
                }
            }
        }

        // Competing terms: score each against the audio at up to three of the word's places, in its sentence.
        var audio: [String: [String: Double]] = [:]
        if audioMargin > 0 {
            let samples = try AudioLoader.loadMono16k(URL(filePath: self.audio))
            let scorer = try AudioScorer(modelURL: URL(filePath: scoringModel))
            for unit in order {
                guard let found = options[unit], Set(found.values.map { $0.match.term.lowercased() }).count > 1 else { continue }
                let keys = Array(found.keys)
                var sums: [String: Double] = [:]
                let heardAt = places[unit]!.prefix(3)
                for place in heardAt {
                    let segment = hebrew.segments[place.segment]
                    let word = words[place.segment][place.word].text
                    guard let range = word.range(of: unit) else { continue }
                    let from = max(0, Int((segment.start - 0.3) * AudioLoader.sampleRate))
                    let to = min(samples.count, Int((segment.end + 0.3) * AudioLoader.sampleRate))
                    try scorer.listen(to: samples[from..<max(from, to)])
                    let alternatives = [word] + keys.map { key in
                        var text = word
                        text.replaceSubrange(range, with: VocabularyRewriter.inflected(found[key]!.match, unit: unit).replacement)
                        return text
                    }
                    let texts = alternatives.map { alternative in
                        var shown = words[place.segment].map(\.text)
                        shown[place.word] = alternative
                        return shown.joined(separator: " ")
                    }
                    let scores = scorer.scores(of: texts, language: hebrew.language)
                    for (key, score) in zip(keys, scores.dropFirst()) { sums[key, default: 0] += score - scores[0] }
                }
                audio[unit] = sums.mapValues { $0 / Double(heardAt.count) }
            }
        }
        func kept(_ unit: String, _ key: String) -> Bool {
            guard let scores = audio[unit], let best = scores.values.max() else { return true }
            return (scores[key] ?? -.infinity) >= best - audioMargin
        }

        let text = words.flatMap { $0.map(\.text) }.joined(separator: " ")
        let candidates = order.compactMap { unit -> VocabularyRewriter.Candidate? in
            let matches = (options[unit] ?? [:]).filter { kept(unit, $0.key) }.values.map(\.match)
                .sorted { ($0.prefix, $0.term) < ($1.prefix, $1.term) }
            guard !matches.isEmpty, let place = places[unit]?.first else { return nil }
            return .init(unit: unit, matches: matches, context: VocabularyRewriter.context(of: words[place.segment][place.word].text, in: text))
        }
        let model = try LanguageModel(modelURL: BekitzurPaths.languageModel)
        var report = VocabularyRewriter.Report()
        let chosen = VocabularyRewriter(vocabulary: vocabulary, model: model).choose(candidates, report: &report)

        let lines: [String] = hebrew.segments.indices.map { s -> String in
            words[s].map { word -> String in
                guard let unit = unit(of: word.text), let match = chosen[unit], let range = word.text.range(of: unit) else { return word.text }
                var text = word.text
                text.replaceSubrange(range, with: VocabularyRewriter.inflected(match, unit: unit).replacement)
                return text
            }.joined(separator: " ")
        }
        try lines.joined(separator: "\n").write(to: URL(filePath: out), atomically: true, encoding: .utf8)

        if let decisions {
            let entries = order.compactMap { unit -> Decision? in
                guard let found = options[unit] else { return nil }
                let proposals = found.sorted { $0.key < $1.key }.map { key, value in
                    Proposal(replacement: value.match.replacement, sources: value.sources.sorted(), audio: audio[unit]?[key], kept: kept(unit, key))
                }
                return Decision(unit: unit, occurrences: places[unit]?.count ?? 0, proposals: proposals, chosen: chosen[unit]?.replacement)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(entries).write(to: URL(filePath: decisions))
        }

        let sources = order.compactMap { options[$0].map { Set($0.values.flatMap(\.sources)) } }
        log(String(
            format: "%d words with candidates (%d only from the list, %d only from the English run, %d from both), %d narrowed by the audio; %d confirmed, %d rejected, %d failed batches; %.1f s",
            sources.count, sources.filter { $0 == ["list"] }.count, sources.filter { $0 == ["english"] }.count,
            sources.filter { $0.count == 2 }.count, audio.count, chosen.count, candidates.count - chosen.count, report.failedBatches,
            Date().timeIntervalSince(started)
        ))
    }

    /// The word, each part of a hyphenated one, or its singular, is in the list.
    private static func isWord(_ word: String, in known: Set<String>) -> Bool {
        let word = word.lowercased()
        if known.contains(word) { return true }
        return word.split(separator: "-").allSatisfy { part in
            let part = String(part)
            let singulars = [part, part.hasSuffix("ies") ? String(part.dropLast(3)) + "y" : nil,
                             part.hasSuffix("es") ? String(part.dropLast(2)) : nil, part.hasSuffix("s") ? String(part.dropLast()) : nil]
            return singulars.compactMap { $0 }.contains(where: known.contains)
        }
    }

    private static func englishWords(_ transcript: Transcript) -> [(start: Double, end: Double, word: String)] {
        transcript.segments.flatMap { segment in
            segment.text.matches(of: /[A-Za-z][A-Za-z0-9\-]*/)
                .map { String($0.output).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
                .filter { $0.count >= 3 && !commonWords.contains($0.lowercased()) }
                .map { (segment.start, segment.end, $0) }
        }
    }
}
