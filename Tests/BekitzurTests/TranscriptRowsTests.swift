import BekitzurDomain
import Testing

/// Each Speaker's speech in lines, and the lines of people who talk at once together in a row.
struct TranscriptRowsTests {
    /// Words a third of a second apart, each a quarter of a second long.
    private func words(_ speaker: String, from start: Double, count: Int) -> [(start: Double, end: Double, speaker: String)] {
        (0..<count).map { (start + Double($0) / 3, start + Double($0) / 3 + 0.25, speaker) }
    }

    /// The rows' lines, each as its Speaker and how many words it has.
    private func shape(_ rows: [[[Int]]], _ words: [(start: Double, end: Double, speaker: String)]) -> [[String]] {
        rows.map { row in row.map { "\(words[$0[0]].speaker) \($0.count)" } }
    }

    @Test func speechWithoutOverlapsReadsAsBefore() {
        let all = words("A", from: 0, count: 6) + words("B", from: 2.2, count: 3) + words("A", from: 3.5, count: 4)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"], ["B 3"], ["A 4"]])
    }

    @Test func aPauseOnItsOwnDoesntSplitALine() {
        let all = words("A", from: 0, count: 3) + words("A", from: 4, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"]])
    }

    /// Lines in time order: B starts talking over A, and A goes on.
    @Test func peopleTalkingAtOnceShareARow() {
        let all = words("A", from: 0, count: 9) + words("B", from: 1, count: 4)

        let rows = TranscriptRows.layout(all)

        #expect(shape(rows, all) == [["A 9", "B 4"]])
        #expect(rows[0][0].map { all[$0].start } == rows[0][0].map { all[$0].start }.sorted())
    }

    @Test func aShortReplyOverSomeoneSharesTheirRow() {
        let all = words("A", from: 0, count: 9) + [(1.4, 1.6, "B")]

        #expect(shape(TranscriptRows.layout(all), all) == [["A 9", "B 1"]])
    }

    @Test func aReplyInAPauseIsAnExchange() {
        let all = words("A", from: 0, count: 3) + [(0.95, 1.2, "B")] + words("A", from: 1.3, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 3"], ["B 1"], ["A 3"]])
    }

    /// Speech recognition times the end of one person and the start of the next a little over each other.
    @Test func onePersonStartingAsTheOtherStopsIsntTalkingAtOnce() {
        let all = words("A", from: 0, count: 6) + words("B", from: 1.75, count: 6)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 6"], ["B 6"]])
    }

    @Test func aWordTimedAsTakingNoTimeIsntAReplyInAPause() {
        let all = [(0.0, 0.25, "A"), (0.33, 0.45, "A"), (0.65, 0.9, "A"), (0.52, 0.52, "B")]

        #expect(shape(TranscriptRows.layout(all), all) == [["A 3", "B 1"]])
    }

    @Test func aWordTimedSecondsLongDoesntHoldItsLineOverTheReplyAfterIt() {
        let all = [(0.0, 0.25, "A"), (0.33, 6.0, "A")] + words("B", from: 1.5, count: 3) + words("A", from: 3, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 2"], ["B 3"], ["A 3"]])
    }

    @Test func aSpeakersLinesInARowAreOne() {
        let all = words("A", from: 0, count: 6) + [(1.0, 1.2, "C")] + words("B", from: 0.5, count: 9) + words("A", from: 2.2, count: 3)

        #expect(shape(TranscriptRows.layout(all), all) == [["A 9", "B 9", "C 1"]])
    }
}
