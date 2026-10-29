import BekitzurDomain
import Testing

struct TranscriptSearchTests {
    private let words = ["Module", "נאים", "חדש", "היום", "module", "name", "המודול"]

    @Test func findsWordsWhateverTheirCase() {
        #expect(TranscriptSearch.matches(of: "MODULE", in: words) == [0...0, 4...4])
    }

    @Test func findsPhrasesAcrossWords() {
        #expect(TranscriptSearch.matches(of: "module  name", in: words) == [4...5])
        #expect(TranscriptSearch.matches(of: "חדש היום", in: words) == [2...3])
        #expect(TranscriptSearch.matches(of: "ule nam", in: words) == [4...5])
    }

    @Test func findsPartsOfWords() {
        #expect(TranscriptSearch.matches(of: "מודול", in: words) == [6...6])
        #expect(TranscriptSearch.matches(of: "dul", in: words) == [0...0, 4...4])
    }

    @Test func ignoresNiqqud() {
        #expect(TranscriptSearch.matches(of: "שלום", in: ["שָׁלוֹם", "לכולם"]) == [0...0])
    }

    @Test func aWordWithTheQueryTwiceCountsOnce() {
        #expect(TranscriptSearch.matches(of: "na", in: ["banana", "name"]) == [0...0, 1...1])
    }

    @Test func nothingToFindFindsNothing() {
        #expect(TranscriptSearch.matches(of: "  ", in: words).isEmpty)
        #expect(TranscriptSearch.matches(of: "zzz", in: words).isEmpty)
        #expect(TranscriptSearch.matches(of: "module", in: []).isEmpty)
    }
}
