import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurPipeline
import BekitzurTranscription
import BekitzurVocabulary
import Foundation

struct AudioCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio-check",
        abstract: "Experiment: score every word that sounds like a Vocabulary term against its audio, as transcribed and with each matched term."
    )

    @Argument(help: "Audio file.")
    var audio: String

    @Argument(help: "Engine Transcript JSON for the audio, from transcribe --json without --speakers.")
    var transcript: String

    @Option(help: "Speech model that does the scoring.")
    var model: String = BekitzurPaths.speechModel(for: .hebrew).path

    @Option(help: "Vocabulary file.")
    var vocabulary: String = BekitzurPaths.vocabulary.path

    @Option(parsing: .upToNextOption, help: "Terms to leave out of the Vocabulary.")
    var without: [String] = []

    @Option(help: "Write the scores as JSON to this file.")
    var json: String

    struct Alternative: Codable {
        let text: String
        let term: String?
        let score: Double
    }

    struct Occurrence: Codable {
        let segment: Int
        let word: Int
        let start: Double
        let alternatives: [Alternative]
    }

    func run() async throws {
        let started = Date()
        let samples = try AudioLoader.loadMono16k(URL(filePath: audio))
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(filePath: self.transcript)))
        let leftOut = Set(without.map { $0.lowercased() })
        let terms = VocabularyStore.terms(with: VocabularyStore(url: URL(filePath: vocabulary)).load())
            .filter { !leftOut.contains($0.lowercased()) }
        let matcher = SoundMatcher(terms: terms)
        let scorer = try AudioScorer(modelURL: URL(filePath: model))

        var occurrences: [Occurrence] = []
        var segmentsHeard = 0
        for (s, segment) in transcript.segments.enumerated() {
            guard let words = segment.words else { continue }
            var found: [(word: Int, alternatives: [(text: String, term: String?)])] = []
            for (w, word) in words.enumerated() {
                guard let unit = SoundMatcher.unit(in: word.text), let range = word.text.range(of: unit) else { continue }
                let matches = matcher.matches(unit)
                guard !matches.isEmpty else { continue }
                let rewrites = matches.map { match -> (text: String, term: String?) in
                    let inflected = VocabularyRewriter.inflected(match, unit: unit)
                    var text = word.text
                    text.replaceSubrange(range, with: inflected.replacement)
                    return (text, inflected.term)
                }
                found.append((w, [(word.text, nil)] + rewrites))
            }
            guard !found.isEmpty else { continue }
            let from = max(0, Int((segment.start - 0.3) * AudioLoader.sampleRate))
            let to = min(samples.count, Int((segment.end + 0.3) * AudioLoader.sampleRate))
            try scorer.listen(to: samples[from..<max(from, to)])
            segmentsHeard += 1
            for item in found {
                let texts = item.alternatives.map { alternative in
                    var shown = words.map(\.text)
                    shown[item.word] = alternative.text
                    return shown.joined(separator: " ")
                }
                let scores = scorer.scores(of: texts, language: transcript.language)
                occurrences.append(Occurrence(
                    segment: s,
                    word: item.word,
                    start: words[item.word].start,
                    alternatives: zip(item.alternatives, scores).map { Alternative(text: $0.0.text, term: $0.0.term, score: $0.1) }
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(occurrences).write(to: URL(filePath: json))
        log(String(format: "%d words in %d segments scored in %.1f s", occurrences.count, segmentsHeard, Date().timeIntervalSince(started)))
    }
}
