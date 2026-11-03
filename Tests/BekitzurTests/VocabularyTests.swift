import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurVocabulary

struct VocabularyTests {
    private let matcher = SoundMatcher(terms: ["zeppelin", "gateway", "kubernetes", "on-call", "deploy", "pipeline"])

    @Test(arguments: [
        ("זפלין", "zeppelin"),
        ("הגייטווי", "ה-gateway"),
        ("קוברנטיס", "kubernetes"),
        ("און-קול", "on-call"),
        ("לדפלוי", "ל-deploy"),
        ("הפייפליין", "ה-pipeline"),
    ])
    func hebrewSpellingsOfTermsMatch(word: String, expected: String) {
        #expect(matcher.matches(word).map(\.replacement) == [expected])
    }

    @Test(arguments: ["שלום", "לא", "אנחנו", "העונקו", "תודה"])
    func ordinaryHebrewWordsDont(word: String) {
        #expect(matcher.matches(word).isEmpty)
    }

    @Test func aHyphenatedPairMustMatchExactly() {
        #expect(SoundMatcher.unit(in: "הזפלין,") == "הזפלין")
        #expect(SoundMatcher.unit(in: "און-קול.") == "און-קול")
        #expect(SoundMatcher.unit(in: "ה-gateway") == nil || matcher.matches(SoundMatcher.unit(in: "ה-gateway")!).isEmpty)
    }

    @Test func correctionsTeachASpellingWithoutItsPrefix() {
        #expect(VocabularyStore.spelling(of: "הזפלין", correctedTo: "Zeppelin")! == ("זפלין", "Zeppelin"))
        #expect(VocabularyStore.spelling(of: "הזפלין", correctedTo: "ה-Zeppelin")! == ("זפלין", "Zeppelin"))
        #expect(VocabularyStore.spelling(of: "האינבנטורי", correctedTo: "הInventory")! == ("אינבנטורי", "Inventory"))
        #expect(VocabularyStore.spelling(of: "בפאבסה", correctedTo: "בPubSub")! == ("פאבסה", "PubSub"))
        #expect(VocabularyStore.spelling(of: "מרצה", correctedTo: "מעדיף") == nil)
    }

    /// A name ("Atlas" typed for "ב-atlasing") would teach "ב", which would then rewrite "ב-GRPC" as "Atlas-GRPC".
    @Test func aWordThatIsOnlyAPrefixTeachesNothingAndOldSuchSpellingsAreDropped() throws {
        #expect(VocabularyStore.spelling(of: "ב", correctedTo: "Atlas") == nil)

        let store = VocabularyStore(url: FileManager.default.temporaryDirectory.appending(path: "vocabulary-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.url) }
        try #require(store.learn(transcribed: "ב-atlasing", correction: "Atlas") == nil)
        try store.save(Vocabulary(spellings: ["ב": "Atlas-infra", "אקספקט": "expect"]))

        #expect(store.load().spellings == ["אקספקט": "expect"])
    }

    @Test func learningSavesTheSpellingAndANewTerm() throws {
        let store = VocabularyStore(url: FileManager.default.temporaryDirectory.appending(path: "vocabulary-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.url) }

        try store.learn(transcribed: "הזפלין,", correction: "Zeppelin")
        try store.learn(transcribed: "הגייטווי", correction: "gateway")

        #expect(store.load().spellings == ["זפלין": "Zeppelin", "גייטווי": "gateway"])
        #expect(store.load().terms == ["Zeppelin"])
    }

    @Test func theRewriteAppliesTaughtSpellingsAndConfirmedMatchesAndKeepsWhatWasTranscribed() {
        let words = [("הזפלין", 1.0), ("עולה", 1.4), ("על", 1.8), ("הגייטווי,", 2.0), ("לא", 2.6), ("קוברנטיס", 3.0)]
            .map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 1, end: 3, text: words.map(\.text).joined(separator: " "), speaker: "Speaker 1", words: words),
        ])
        var asked: [String] = []
        let rewriter = VocabularyRewriter(vocabulary: Vocabulary(spellings: ["זפלין": "Zeppelin"])) { candidates, _ in
            asked = candidates.map(\.unit)
            // The model confirms the gateway and rejects Kubernetes.
            return Dictionary(uniqueKeysWithValues: candidates.filter { $0.unit == "הגייטווי" }.map { ($0.unit, $0.matches[0]) })
        }

        let (rewritten, report) = rewriter.rewrite(transcript)

        #expect(asked == ["הגייטווי", "קוברנטיס"])
        #expect(rewritten.segments[0].text == "ה-Zeppelin עולה על ה-gateway, לא קוברנטיס")
        #expect(rewritten.segments[0].words?[3].transcribed == "הגייטווי,")
        #expect((report.learned, report.verified, report.rejected) == (1, 1, 1))
    }

    @Test func rewritingAgainStartsFromWhatWasTranscribed() {
        // Rewritten before the user taught "skill", and with the prefix-only spelling "ב".
        let words = [
            TranscriptWord(start: 1, end: 1.4, text: "scale", transcribed: "סקיל"),
            TranscriptWord(start: 1.5, end: 1.9, text: "Atlas-GRPC", transcribed: "ב-GRPC"),
        ]
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 1, end: 2, text: "scale Atlas-GRPC", speaker: "Speaker 1", words: words),
        ])
        let rewriter = VocabularyRewriter(vocabulary: Vocabulary(spellings: ["סקיל": "skill"])) { _, _ in [:] }

        let rewritten = rewriter.rewrite(transcript).0

        #expect(rewritten.segments[0].text == "skill ב-GRPC")
        #expect(rewritten.segments[0].words?.map(\.transcribed) == ["סקיל", nil])
    }

    @Test(arguments: [
        ("הפרטישנים", "ה", "partition", "ה-partitions"),
        ("קליינטס", "", "client", "clients"),
        ("סרוויס", "", "service", "service"),
        ("קוברנטיס", "", "kubernetes", "kubernetes"),
        ("הסקיידולר", "ה", "scheduler", "ה-scheduler"),
        ("טסטים", "", "tests", "tests"),
        ("פרוססים", "", "process", "processes"),
    ])
    func pluralWordsKeepTheirPlural(unit: String, prefix: String, term: String, expected: String) {
        #expect(VocabularyRewriter.inflected(SoundMatcher.Match(prefix: prefix, term: term), unit: unit).replacement == expected)
    }

    @Test func marksStillFindAWordTheVocabularyRewrote() {
        let transcribed = TranscriptWord(start: 2, end: 2, text: "הגייטווי,")
        var flags = TranscriptFlags()
        flags.toggle(transcribed)

        let rewritten = TranscriptWord(start: 2, end: 2, text: "ה-gateway,", transcribed: "הגייטווי,")
        #expect(flags.flag(for: rewritten) != nil)
    }
}
