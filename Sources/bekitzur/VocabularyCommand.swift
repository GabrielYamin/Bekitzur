import ArgumentParser
import BekitzurDomain
import BekitzurNotes
import BekitzurPipeline
import BekitzurVocabulary
import Foundation

struct VocabularyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocabulary",
        abstract: "Write English terms that a Hebrew Transcript spells in Hebrew letters in English letters, as the app does."
    )

    @Argument(help: "Engine Transcript JSON, from transcribe --json.")
    var input: String

    @Flag(help: "Only list the words that sound like a term, without asking the language model.")
    var candidates = false

    @Flag(help: "With --candidates: strict matching (three sounds or more, one difference only from five).")
    var strict = false

    @Option(help: "Vocabulary file.")
    var vocabulary: String = BekitzurPaths.vocabulary.path

    @Option(help: "Write the rewritten text, one segment per line, to this file.")
    var out: String?

    func run() async throws {
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(filePath: input)))
        let vocabulary = VocabularyStore(url: URL(filePath: self.vocabulary)).load()
        if candidates {
            let matcher = SoundMatcher(terms: VocabularyStore.terms(with: vocabulary), loose: !strict)
            var seen = Set<String>()
            for word in transcript.segments.flatMap({ $0.words ?? [] }) {
                guard let unit = SoundMatcher.unit(in: word.text), seen.insert(unit).inserted else { continue }
                let matches = matcher.matches(unit)
                if !matches.isEmpty { print("\(unit)\t\(matches.map(\.replacement).joined(separator: ", "))") }
            }
            return
        }
        let started = Date()
        let model = try LanguageModel(modelURL: BekitzurPaths.languageModel)
        let (rewritten, report) = VocabularyRewriter(vocabulary: vocabulary, model: model).rewrite(transcript)
        for word in rewritten.segments.flatMap({ $0.words ?? [] }) where word.transcribed != nil {
            print("\(word.transcribed!) → \(word.text)")
        }
        log(String(
            format: "%d from taught spellings, %d confirmed, %d rejected, %d failed batches; %d prompt and %d output tokens; %.1f s",
            report.learned, report.verified, report.rejected, report.failedBatches, report.promptTokens, report.outputTokens,
            Date().timeIntervalSince(started)
        ))
        if let out {
            try rewritten.segments.map(\.text).joined(separator: "\n").write(to: URL(filePath: out), atomically: true, encoding: .utf8)
        }
    }
}
