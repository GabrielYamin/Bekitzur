import BekitzurDomain
import Testing

/// Each Speaker's speech in lines, and the lines of people who talk at once together in a row.
struct TranscriptRowsTests {
    private typealias Word = (start: Double, end: Double, speaker: String)

    /// Words a third of a second apart, each a quarter of a second long.
    private func words(_ speaker: String, from start: Double, count: Int) -> [Word] {
        (0..<count).map { i -> Word in
            let at: Double = start + Double(i) / 3
            return (at, at + 0.25, speaker)
        }
    }

    private func word(_ start: Double, _ end: Double, _ speaker: String) -> [Word] {
        [(start, end, speaker)]
    }

    /// The rows' lines, each as its Speaker and how many words it has.
    private func shape(_ rows: [[[Int]]], _ words: [Word]) -> [[String]] {
        rows.map { row -> [String] in
            row.map { line -> String in "\(words[line[0]].speaker) \(line.count)" }
        }
    }

    @Test func speechWithoutOverlapsReadsAsBefore() {
        var all = words("A", from: 0, count: 6)
        all += words("B", from: 2.2, count: 3)
        all += words("A", from: 3.5, count: 4)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"], ["B 3"], ["A 4"]])
    }

    @Test func aPauseOnItsOwnDoesntSplitALine() {
        var all = words("A", from: 0, count: 3)
        all += words("A", from: 4, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"]])
    }

    /// Lines in time order: B starts talking over A, and A goes on.
    @Test func peopleTalkingAtOnceShareARow() {
        var all = words("A", from: 0, count: 9)
        all += words("B", from: 1, count: 4)

        let rows = TranscriptRows.layout(all)
        let starts: [Double] = rows[0][0].map { all[$0].start }

        #expect(shape(rows, all) == [["A 9", "B 4"]])
        #expect(starts == starts.sorted())
    }

    /// A "כן" over someone's sentence: they don't talk at once for a second, so it reads after the sentence.
    @Test func aShortReplyOverSomeoneReadsAfterThem() {
        var all = words("A", from: 0, count: 9)
        all += word(1.4, 1.6, "B")

        #expect(shape(TranscriptRows.layout(all), all) == [["A 9"], ["B 1"]])
    }

    /// B starts as A goes on, and they talk at once for 0.6 seconds by their words' times.
    @Test func talkingAtOnceForLessThanASecondIsntARow() {
        var all = words("A", from: 0, count: 6)
        all += words("B", from: 1.3, count: 4)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"], ["B 4"]])
    }

    @Test func aReplyInAPauseIsAnExchange() {
        var all = words("A", from: 0, count: 3)
        all += word(0.95, 1.2, "B")
        all += words("A", from: 1.3, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 3"], ["B 1"], ["A 3"]])
    }

    /// Speech recognition times the end of one person and the start of the next a little over each other.
    @Test func onePersonStartingAsTheOtherStopsIsntTalkingAtOnce() {
        var all = words("A", from: 0, count: 6)
        all += words("B", from: 1.75, count: 6)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"], ["B 6"]])
    }

    @Test func aWordTimedAsTakingNoTimeIsntAReplyInAPause() {
        var all = word(0.0, 0.25, "A")
        all += word(0.33, 0.45, "A")
        all += word(0.65, 0.9, "A")
        all += word(0.52, 0.52, "B")

        #expect(shape(TranscriptRows.layout(all), all) == [["A 3"], ["B 1"]])
    }

    @Test func aWordTimedSecondsLongDoesntHoldItsLineOverTheReplyAfterIt() {
        var all = word(0.0, 0.25, "A")
        all += word(0.33, 6.0, "A")
        all += words("B", from: 1.5, count: 3)
        all += words("A", from: 3, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 2"], ["B 3"], ["A 3"]])
    }

    /// B starts talking over A's last words, but speech recognition times B's first words as A finishes. What each says
    /// alone, before and after, reads as a line of its own.
    @Test func whatTheTimelineHeardAtOnceSharesARow() {
        var all = words("A", from: 15.83, count: 12)
        all += words("B", from: 19.69, count: 6)
        let heard: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 20.4, ["A", "B"])]
        let others: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 20.4, ["A", "C"])]

        #expect(shape(TranscriptRows.layout(all), all) == [["A 12"], ["B 6"]])
        #expect(shape(TranscriptRows.layout(all, together: heard), all) == [["A 9"], ["A 3", "B 3"], ["B 3"]])
        #expect(shape(TranscriptRows.layout(all, together: others), all) == [["A 12"], ["B 6"]])
    }

    /// A starts two words before the timeline hears B too, and B goes on two words after: cut off, they'd read as lines
    /// cut short.
    @Test func aWordOrTwoAroundWhatWasSaidAtOnceStayWithIt() {
        var all = words("A", from: 18.0, count: 5)
        all += words("B", from: 19.69, count: 5)
        let heard: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 20.4, ["A", "B"])]

        #expect(shape(TranscriptRows.layout(all, together: heard), all) == [["A 5", "B 5"]])
    }

    /// The same, but A's two words end a sentence, and so does what B says at once: theirs are sentences of their own.
    @Test func aSentenceOfAWordOrTwoAroundWhatWasSaidAtOnceIsALineOfItsOwn() {
        var all = words("A", from: 18.0, count: 5)
        all += words("B", from: 19.69, count: 5)
        let heard: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 20.4, ["A", "B"])]

        #expect(shape(TranscriptRows.layout(all, together: heard, endingSentences: [1, 7]), all) == [["A 2"], ["A 3", "B 3"], ["B 2"]])
    }

    @Test func stretchesAMomentApartAreOne() {
        var all = words("A", from: 15.83, count: 12)
        all += words("B", from: 19.69, count: 9)
        let heard: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 20.4, ["A", "B"]), (20.77, 22.8, ["A", "B"])]

        #expect(shape(TranscriptRows.layout(all, together: heard), all) == [["A 9"], ["A 3", "B 9"]])
    }

    /// The timeline hears A and B at once for 0.6 seconds: one starting as the other stops. Two such moments a pause
    /// apart, a second in all, are talking at once.
    @Test func whatTheTimelineHeardAtOnceForLessThanASecondIsntARow() {
        var all = words("A", from: 15.83, count: 12)
        all += words("B", from: 19.69, count: 6)
        let briefly: [(start: Double, end: Double, speakers: Set<String>)] = [(19.5, 20.1, ["A", "B"])]
        let twice: [(start: Double, end: Double, speakers: Set<String>)] = [(18.78, 19.3, ["A", "B"]), (19.9, 20.4, ["A", "B"])]

        #expect(shape(TranscriptRows.layout(all, together: briefly), all) == [["A 12"], ["B 6"]])
        #expect(shape(TranscriptRows.layout(all, together: twice), all) == [["A 9"], ["A 3", "B 3"], ["B 3"]])
    }

    /// B's word in A's pause cuts A's line in two, and both of A's lines are said with B.
    @Test func aSpeakersLinesInARowAreOne() {
        var all = words("A", from: 0, count: 6)
        all += words("B", from: 0.4, count: 12)
        all += words("A", from: 2.3, count: 6)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 12", "B 12"]])
    }

    /// C says a word while A and B talk at once: it reads after their row, which A's next line still joins.
    @Test func aReplyWhilePeopleTalkAtOnceReadsAfterThem() {
        var all = words("A", from: 0, count: 6)
        all += words("B", from: 0.4, count: 12)
        all += words("A", from: 2.3, count: 6)
        all += word(1.0, 1.2, "C")

        #expect(shape(TranscriptRows.layout(all), all) == [["A 12", "B 12"], ["C 1"]])
    }
}
