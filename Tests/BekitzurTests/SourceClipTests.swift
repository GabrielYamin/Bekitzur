import Foundation
import Testing
@testable import BekitzurDomain

/// What a Source plays in place: the words its item quotes, from a little before them.
struct SourceClipTests {
    private static func word(_ start: Double, _ end: Double, _ text: String) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text)
    }

    private let transcript = Transcript(language: .hebrew, segments: [
        TranscriptSegment(start: 10, end: 12, text: "מה עם הדוח?", speaker: "Dana", words: [
            word(10, 10.5, "מה"), word(10.6, 11, "עם"), word(11.1, 12, "הדוח?"),
        ]),
        TranscriptSegment(start: 14, end: 19.5, text: "אני אשלח אותו מחר בבוקר, אחרי הישיבה.", speaker: "Speaker 2", words: [
            word(14, 14.4, "אני"), word(14.5, 15, "אשלח"), word(15.1, 15.5, "אותו"), word(16, 16.4, "מחר"),
            word(16.5, 17, "בבוקר,"), word(18, 18.5, "אחרי"), word(18.6, 19.5, "הישיבה."),
        ]),
        TranscriptSegment(start: 20, end: 70, text: "…", speaker: "Speaker 2", words: (0..<50).map { word(20 + Double($0), 20.5 + Double($0), "עוד") }),
    ])

    private func clip(_ quote: String?, speaker: String = "Speaker 2", start: Double? = 14, end: Double? = 70) -> SourceClip? {
        SourceClip(quote: quote, speaker: speaker, start: start, end: end, in: transcript)
    }

    @Test func itPlaysTheQuotedWordsFromALittleBefore() throws {
        let found = try #require(clip("אשלח אותו מחר"))
        let quoted = found.words.filter(\.quoted).map(\.text)

        #expect(found.range == 12.5...16.9)
        #expect(found.speaker == "Speaker 2")
        #expect(found.words.map(\.text) == ["אני", "אשלח", "אותו", "מחר"])
        #expect(quoted == ["אשלח", "אותו", "מחר"])
    }

    @Test func punctuationDoesntGetInTheWay() {
        #expect(clip("מחר בבוקר, אחרי הישיבה")?.range == 14...20)
    }

    /// The model can quote a word a little differently from the Transcript.
    @Test func aQuoteOffByAWordIsStillFound() {
        #expect(clip("אני אשלח אותה מחר")?.range == 12...16.9)
    }

    /// Like an Open Question's Source, which quotes nothing.
    @Test func withoutTheQuoteItsTheStartOfTheTurn() throws {
        let missing = try #require(clip("something else entirely"))
        let quoted = missing.words.filter(\.quoted)

        #expect(missing.range == 14...44)
        #expect(missing.words.first?.text == "אני")
        #expect(quoted.isEmpty)
        #expect(clip(nil)?.range == 14...44)
    }

    /// Separating people who talked at once, or a fix, can give the quoted words to someone else after the Notes are
    /// written.
    @Test func aQuoteSaidElsewhereIsFoundWhereItWas() throws {
        let elsewhere = try #require(clip("מה עם הדוח"))

        #expect(elsewhere.range == 8...12.5)
        #expect(elsewhere.speaker == "Dana")
        #expect(elsewhere.words.map(\.text) == ["מה", "עם", "הדוח?"])
    }

    /// In its own turn, half the quote's words find it; anywhere else, that's too few.
    @Test func aLooseQuoteIsFoundOnlyInItsTurn() {
        #expect(clip("אני אשלח אותה בערב")?.range == 12...16.9)
        #expect(clip("אני אשלח אותה בערב", start: 20)?.range == 20...50)
    }

    /// An answer's quote knows only where its turn starts.
    @Test func aTurnKnownByItsStartIsSearchedOn() {
        #expect(clip("אחרי הישיבה", end: nil)?.range == 16...20)
    }

    @Test func aTurnWithoutAStartHasNoClip() {
        #expect(clip("אשלח", start: nil) == nil)
    }
}
