import BekitzurDomain
import Testing

struct MultiWordCorrectionTests {
    private let words = [
        TranscriptWord(start: 1.0, end: 1.4, text: "מודול"),
        TranscriptWord(start: 1.5, end: 1.9, text: "נאים"),
        TranscriptWord(start: 2.0, end: 2.3, text: "חדש"),
    ]

    @Test func typedWordsGoToTheSelectedWordsInOrder() {
        #expect(TranscriptFlags.spread("module name", over: 2) == ["module", "name"])
        // Fewer typed words: the rest weren't said. More: the last word takes them.
        #expect(TranscriptFlags.spread("database", over: 2) == ["database", ""])
        #expect(TranscriptFlags.spread("the module name", over: 2) == ["the", "module name"])
        #expect(TranscriptFlags.spread("  ", over: 2) == [nil, nil])
    }

    @Test func aPhraseIsCorrectedWordByWord() {
        var flags = TranscriptFlags()

        flags.correct(Array(words[0...1]), as: "module name")

        #expect(flags.text(of: words[0]) == "module")
        #expect(flags.text(of: words[1]) == "name")
        #expect(flags.text(of: words[2]) == "חדש")
    }

    @Test func wordsNotSaidAreLeftOutOfTheTranscriptTheNotesAreWrittenFrom() {
        var flags = TranscriptFlags()
        flags.correct(Array(words[0...1]), as: "database")
        let transcript = Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 1.0, end: 2.3, text: "מודול נאים חדש", speaker: "Speaker 1", words: words),
        ])

        let fixed = transcript.applying(flags)

        #expect(flags.fixes.count == 2)
        #expect(fixed.segments.map(\.text) == ["database חדש"])
        #expect(fixed.segments.first?.words?.count == 2)
    }

    @Test func typingNothingForAPhraseMarksItWrong() {
        var flags = TranscriptFlags()

        flags.correct(Array(words[0...1]), as: "")

        #expect(flags.words.count == 2)
        #expect(flags.fixes.isEmpty)
    }

    @Test func aPhraseIsMarkedWrongOrClearedAtOnce() {
        var flags = TranscriptFlags()
        flags.toggle(words[1])

        flags.mark(words, wrong: true)
        #expect(flags.words.count == 3)

        flags.correct([words[0]], as: "module")
        flags.mark(words, wrong: false)
        #expect(flags.words.isEmpty)
    }
}
