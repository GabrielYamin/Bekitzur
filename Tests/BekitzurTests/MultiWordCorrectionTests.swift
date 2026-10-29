import BekitzurDomain
import Testing

struct MultiWordCorrectionTests {
    private let words = [
        TranscriptWord(start: 1.0, end: 1.4, text: "מודול"),
        TranscriptWord(start: 1.5, end: 1.9, text: "נאים"),
        TranscriptWord(start: 2.0, end: 2.3, text: "חדש"),
        TranscriptWord(start: 2.4, end: 2.8, text: "היום"),
    ]

    private var transcript: Transcript {
        Transcript(language: .hebrew, segments: [
            TranscriptSegment(start: 1.0, end: 2.8, text: "מודול נאים חדש היום", speaker: "Speaker 1", words: words),
        ])
    }

    @Test func wordsCorrectedTogetherAreOnePhrase() {
        var flags = TranscriptFlags()

        flags.correct(Array(words[0...1]), as: "ניסיון אחד שניים שלוש")

        #expect(flags.text(of: words[0]) == "ניסיון אחד שניים שלוש")
        #expect(flags.text(of: words[1]) == "")
        #expect(flags.phraseStart(of: words[0]) == 1.0 && flags.phraseStart(of: words[1]) == 1.0)
        #expect(flags.phraseStart(of: words[2]) == nil)
        #expect(transcript.applying(flags).segments.map(\.text) == ["ניסיון אחד שניים שלוש חדש היום"])
    }

    @Test func aClickOnAnyWordOfAPhraseTakesBackAllOfIt() {
        var flags = TranscriptFlags()
        flags.correct(Array(words[0...2]), as: "module name")
        flags.toggle(words[3])

        flags.toggle(words[1])

        #expect(flags.words.map(\.start) == [2.4])
        #expect(transcript.applying(flags).segments.map(\.text) == ["מודול נאים חדש היום"])
    }

    @Test func aNewCorrectionReplacesAPhraseItTouchesWhole() {
        var flags = TranscriptFlags()
        flags.correct(Array(words[0...1]), as: "module name")

        flags.correct(Array(words[1...2]), as: "new name")

        #expect(flags.flag(for: words[0]) == nil)
        #expect(flags.text(of: words[1]) == "new name" && flags.text(of: words[2]) == "")
    }

    @Test func typingNothingForAPhraseMarksEachWordWrong() {
        var flags = TranscriptFlags()

        flags.correct(Array(words[0...1]), as: "")

        #expect(flags.words.count == 2)
        #expect(flags.fixes.isEmpty)
        #expect(flags.phraseStart(of: words[0]) == nil)
    }

    @Test func wordsAreMarkedWrongOrClearedAtOnce() {
        var flags = TranscriptFlags()
        flags.toggle(words[1])

        flags.mark(words, wrong: true)
        #expect(flags.words.count == 4)

        flags.correct(Array(words[0...1]), as: "module name")
        flags.mark(words, wrong: false)
        #expect(flags.words.isEmpty)
    }
}
