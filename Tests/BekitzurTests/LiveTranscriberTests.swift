import BekitzurAudio
import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurPipeline

struct LiveTranscriberTests {
    /// The scripted read, kept out of git; tests that need it or the speech model run only where both are.
    static let scriptedRead = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../eval/recordings/meeting-1.m4a")
    static let canTranscribe = FileManager.default.fileExists(atPath: scriptedRead.path)
        && FileManager.default.fileExists(atPath: BekitzurPaths.speechModel(for: .hebrew).path)
    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    @Test func aChunkWaitsForTwentySeconds() {
        #expect(LiveTranscriber.cut(speech(15)[...], final: false) == nil)
    }

    @Test func aChunkEndsInThePauseAfterTwentySeconds() throws {
        let audio = speech(22) + silence(0.6) + speech(3)

        let cut = try #require(LiveTranscriber.cut(audio[...], final: false))

        #expect((22 * 16_000...Int(22.6 * 16_000)).contains(cut))
    }

    @Test func withoutAPauseAChunkWaitsUntilThirtySeconds() throws {
        #expect(LiveTranscriber.cut(speech(25)[...], final: false) == nil)

        let cut = try #require(LiveTranscriber.cut(speech(31)[...], final: false))

        #expect((20 * 16_000...30 * 16_000).contains(cut))
    }

    @Test func onceStoppedTheRestIsTheLastChunk() throws {
        #expect(LiveTranscriber.cut(speech(10)[...], final: true) == 160_000)

        let cut = try #require(LiveTranscriber.cut((speech(25) + silence(0.6) + speech(20))[...], final: true))

        #expect((25 * 16_000...Int(25.6 * 16_000)).contains(cut))
    }

    /// whisper.cpp's word timing aborted the app when a window held a segment ending within 0.15 seconds of its start,
    /// as at the end of a short chunk; this fifth of a second of speech did it every time.
    @Test(.enabled(if: canTranscribe))
    func aFifthOfASecondOfSpeechIsTranscribedWithoutAborting() async throws {
        let clip = Array(try AudioLoader.loadMono16k(Self.scriptedRead)[480_000..<483_200])
        let chunks = InProcessChunkTranscriber(language: .hebrew, detectsSpeech: false)
        let live = LiveTranscriber(language: .hebrew, chunks: chunks, tracks: 1) { _ in }

        clip.withUnsafeBufferPointer { live.receive($0, sampleRate: 16_000, track: 0) }

        #expect(await live.finish() != nil)
    }

    @Test func aChunkReachesTheHelperAsItWasSent() throws {
        let samples: [Float] = [0.25, -0.5, 0.125]
        var data = LiveChunks.message(samples, at: 42.5) + LiveChunks.message([], at: 50)

        // A pipe hands over whatever has arrived, so read two bytes at a time.
        let read: (Int) -> Data = { count in
            let piece = data.prefix(min(count, 2))
            data.removeFirst(piece.count)
            return piece
        }
        let first = try #require(LiveChunks.readMessage(read))
        let second = try #require(LiveChunks.readMessage(read))

        #expect(first.samples == samples && first.offset == 42.5)
        #expect(second.samples.isEmpty && second.offset == 50)
        #expect(LiveChunks.readMessage(read) == nil)
    }

    /// The app must outlive its helper: chunks sent after the helper has died get nil, and writing to it doesn't end
    /// the process with SIGPIPE.
    @Test(arguments: ["/usr/bin/false", "/bin/cat"])
    func aHelperThatDiesOrTalksNonsenseEndsOnlyLiveTranscription(helper: String) async {
        let chunks = HelperChunkTranscriber(executable: URL(filePath: helper), arguments: [])
        let live = LiveTranscriber(language: .hebrew, chunks: chunks, tracks: 1) { _ in }
        let speech = (0..<(40 * 16_000)).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 16_000) }

        try? await Task.sleep(for: .milliseconds(200))
        speech.withUnsafeBufferPointer { live.receive($0, sampleRate: 16_000, track: 0) }

        #expect(await live.finish() == nil)
    }

    @Test func speechWithShortPausesIsOnePieceAndLongSilencesAreLeftOut() {
        let pieces = LiveChunks.pieces([12.0...14.5, 0.5...3.0, 3.8...6.0, 25.0...25.9])

        #expect(pieces == [0.5...6.0, 12.0...14.5, 25.0...25.9])
    }

    @Test func sentencesBecomeTheirOwnSegments() {
        let words = ["כן,", "בדיוק.", "מה", "עם", "ה-flag?", "סבבה"].enumerated().map { TranscriptWord(start: Double($0.offset), end: Double($0.offset) + 0.5, text: $0.element) }

        let sentences = LiveChunks.sentences(TranscriptSegment(start: 0, end: 6, text: "", words: words))

        #expect(sentences.map(\.text) == ["כן, בדיוק.", "מה עם ה-flag?", "סבבה"])
        #expect(sentences.map(\.start) == [0, 2, 5])
        #expect(sentences.map(\.end) == [1.5, 4.5, 5.5])
    }

    @Test func aOneSegmentWindowIsTimedByItsWords() {
        let segment = TranscriptSegment(start: 0, end: 30, text: "כן, בדיוק", words: [
            TranscriptWord(start: 2.1, end: 2.4, text: "כן,"),
            TranscriptWord(start: 2.5, end: 3.0, text: "בדיוק"),
        ])

        let fitted = LiveChunks.fitted(segment, end: 24)

        #expect((fitted.start, fitted.end) == (2.1, 3.0))
        #expect(LiveChunks.fitted(TranscriptSegment(start: 0, end: 30, text: "כן"), end: 24).end == 24)
    }

    @Test func aChunkTranscribedOnItsOwnMovesToWhereItWasSaid() {
        let segment = TranscriptSegment(start: 1, end: 2, text: "שלום", words: [TranscriptWord(start: 1.2, end: 1.8, text: "שלום")])

        let shifted = segment.shifted(by: 30)

        #expect((shifted.start, shifted.end) == (31, 32))
        #expect(shifted.words?.map(\.start) == [31.2])
        #expect(shifted.words?.map(\.end) == [31.8])
    }
}
