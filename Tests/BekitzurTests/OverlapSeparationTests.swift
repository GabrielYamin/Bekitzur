import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurPipeline
@testable import BekitzurSpeakers

/// People on the same side talking at once, separated and merged into the Transcript.
struct OverlapSeparationTests {
    /// Speaker 1 talks for 10 seconds; Speaker 2 talks over them from 5 to 7.
    private let activity = Activity([
        SpeakerTurn(voice: "S1", start: 0, end: 10, embedding: [1, 0]),
        SpeakerTurn(voice: "S2", start: 5, end: 7, embedding: [0, 1]),
    ], length: 12)

    private func segment(_ words: [(Double, String)], speaker: String) -> TranscriptSegment {
        let timed = words.map { TranscriptWord(start: $0.0, end: $0.0 + 0.3, text: $0.1) }
        return TranscriptSegment(start: timed[0].start, end: timed.last!.end, text: timed.map(\.text).joined(separator: " "), speaker: speaker, words: timed)
    }

    private func found(_ start: Double, _ text: String, voice: String, probability: Float = 0.9, confidence: Float = 0.9) -> OverlapSeparation.Found {
        OverlapSeparation.Found(
            word: TranscriptWord(start: start, end: start + 0.3, text: text, probability: probability),
            speaker: voice == "S1" ? "Speaker 1" : "Speaker 2",
            voice: voice,
            input: nil,
            confidence: confidence
        )
    }

    @Test func momentsAreWhereTwoVoicesOfOneSideAreHeardAtOnce() {
        let activity = Activity([
            SpeakerTurn(voice: "S1", start: 0, end: 10, embedding: [1, 0]),
            SpeakerTurn(voice: "S2", start: 5, end: 7, embedding: [0, 1]),
            SpeakerTurn(voice: "microphone S1", start: 12, end: 13, embedding: [1, 0], input: .microphone),
            SpeakerTurn(voice: "system S1", start: 12, end: 13, embedding: [0, 1], input: .systemAudio),
        ], length: 14)

        let moments = activity.moments()

        #expect(moments.count == 1)
        #expect(abs(moments[0].start - 5) < 0.02 && abs(moments[0].end - 7) < 0.02 && moments[0].input == nil)
    }

    @Test func eachMomentIsSeparatedWithASecondAroundItJoinedWhereTheyMeet() {
        let windows = OverlapSeparation.windows(around: [
            .init(start: 4, end: 5, input: nil),
            .init(start: 6.5, end: 7, input: nil),
            .init(start: 20, end: 21, input: nil),
            .init(start: 4.2, end: 4.8, input: .microphone),
        ])

        #expect(windows == [
            .init(start: 3, end: 8, input: nil),
            .init(start: 3.2, end: 5.8, input: .microphone),
            .init(start: 19, end: 22, input: nil),
        ])
    }

    /// Liron said "שנבין" over Gabriel, and it was written as Gabriel's.
    @Test func aWordSaidOverSomeoneGoesToWhoeverSeparationHearsSayIt() {
        let segments = [segment([(2.0, "אני"), (2.5, "חושב"), (5.5, "ושנבין"), (8.0, "את"), (8.3, "זה")], speaker: "Speaker 1")]

        let merged = OverlapSeparation.merge(segments, found: [found(5.52, "שנבין", voice: "S2")], activity: activity)

        #expect(merged.segments.map(\.text) == ["אני חושב", "ושנבין", "את זה"])
        #expect(merged.segments.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(merged.moved == 1 && merged.added == 0)
    }

    @Test func awayFromTwoPeopleAtOnceSeparationChangesNothing() {
        let segments = [segment([(2.0, "אני"), (3.0, "חושב")], speaker: "Speaker 1")]

        let merged = OverlapSeparation.merge(segments, found: [found(3.0, "חושב", voice: "S2"), found(8.5, "נכון", voice: "S2")], activity: activity)

        #expect(merged.segments == segments)
    }

    /// Eli said "בנוסף כן" over Gabriel, and speech recognition left it out.
    @Test func wordsOnlyTheSeparatedVoiceHasAreAdded() {
        let segments = [segment([(5.0, "אז"), (5.4, "בוא"), (5.8, "נתחיל")], speaker: "Speaker 1")]

        let merged = OverlapSeparation.merge(segments, found: [found(6.2, "בנוסף", voice: "S2"), found(6.5, "כן", voice: "S2")], activity: activity)

        #expect(merged.segments.map(\.text) == ["אז בוא נתחיל", "בנוסף כן"])
        #expect(merged.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(merged.segments.map(\.separated) == [nil, true])
        #expect(merged.added == 2)
    }

    /// Over a separated voice's sounds that aren't words, speech recognition still writes some, unsure of them.
    @Test func wordsSpeechRecognitionWasUnsureOfAreLeftOut() {
        let segments = [segment([(5.0, "אז"), (5.4, "בוא")], speaker: "Speaker 1")]

        let merged = OverlapSeparation.merge(segments, found: [found(6.2, "בבקשה", voice: "S2", confidence: 0.37)], activity: activity)

        #expect(merged.segments == segments)
    }

    @Test func soundsWrittenOverNoiseAreLeftOut() {
        let segments = [segment([(5.0, "אז")], speaker: "Speaker 1")]

        let merged = OverlapSeparation.merge(segments, found: [found(5.8, "אדוני", voice: "S2"), found(6.4, "אההה", voice: "S2")], activity: activity)

        #expect(merged.added == 0)
    }

    /// Speech recognition can time the same word half a second or more apart in the separated voice.
    @Test func aWordThePersonAlreadySaidASecondAwayIsntAddedAgain() {
        let segments = [segment([(5.0, "אוקיי")], speaker: "Speaker 1"), segment([(6.1, "מבחינת")], speaker: "Speaker 2")]

        let merged = OverlapSeparation.merge(segments, found: [found(5.3, "מבחינת", voice: "S2")], activity: activity)

        #expect(merged.added == 0)
    }

    /// Gabriel stops and David answers "כן, בואו נתחיל ככה": separation keeps both in Gabriel's voice.
    @Test func aWordStaysWithItsSpeakerWhenTheVoiceItsFoundInCarriesThemToo() {
        let activity = Activity([
            SpeakerTurn(voice: "S1", start: 0, end: 6, embedding: [1, 0]),
            SpeakerTurn(voice: "S2", start: 5.8, end: 10, embedding: [0, 1]),
        ], length: 12)
        let segments = [
            segment([(4.0, "שיכתוב"), (5.0, "רק")], speaker: "Speaker 1"),
            segment([(5.85, "-כן,"), (6.5, "בואו"), (6.8, "נתחיל"), (7.2, "ככה.")], speaker: "Speaker 2"),
        ]

        let merged = OverlapSeparation.merge(segments, found: [
            found(5.87, "כן,", voice: "S1", probability: 0.6), found(6.52, "בוא", voice: "S1", probability: 0.98),
            found(6.8, "נתחיל", voice: "S1", probability: 0.71), found(7.2, "כך.", voice: "S1", probability: 0.82),
        ], activity: activity)

        #expect(merged.segments == segments && merged.moved == 0 && merged.added == 0)
    }

    @Test func howSureSpeechRecognitionWasIsTakenPhraseByPhrase() async throws {
        let window = OverlapSeparation.Stretch(start: 10, end: 14, input: nil)
        let words = [(0.5, "אתה", Float(0.2)), (0.7, "מבין", 0.4), (0.9, "את", 0.6), (2.5, "כן", 0.9), (2.8, "בטח", 0.9)]

        let found = try await OverlapSeparation.transcribed([(window, [Float](repeating: 0, count: 64_000))], language: .hebrew) { _, _ in
            let timed = words.map { TranscriptWord(start: $0.0, end: $0.0 + 0.15, text: $0.1, probability: $0.2) }
            return Transcript(language: .hebrew, segments: [TranscriptSegment(start: 0.5, end: 2.95, text: "", words: timed)])
        }

        #expect(found.map { ($0.word.start * 100).rounded() } == [1050, 1070, 1090, 1250, 1280])
        #expect(found.map { ($0.confidence * 100).rounded() } == [40, 40, 40, 90, 90])
    }

    @Test func someoneWithAWordThereAlreadyGetsNoOther() {
        let segments = [segment([(5.0, "אז")], speaker: "Speaker 1"), segment([(6.0, "פה")], speaker: "Speaker 2")]

        let merged = OverlapSeparation.merge(segments, found: [found(6.1, "בה", voice: "S2")], activity: activity)

        #expect(merged.added == 0)
    }

    /// Shai said "כן", and it leaked into the other separated voice too.
    @Test func aWordInBothVoicesGoesToTheOneSurerOfIt() {
        let segments = [segment([(5.0, "אז"), (5.5, "כן")], speaker: "Speaker 1")]

        let leaked = OverlapSeparation.merge(segments, found: [found(5.5, "כן", voice: "S1", probability: 0.3), found(5.52, "כן", voice: "S2")], activity: activity)
        let kept = OverlapSeparation.merge(segments, found: [found(5.5, "כן", voice: "S1"), found(5.52, "כן", voice: "S2", probability: 0.3)], activity: activity)

        #expect(leaked.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"] && leaked.added == 0)
        #expect(kept.segments == segments && kept.added == 0)
    }

    @Test func eachSeparatedVoiceIsNamedAfterTheVoiceHeardWhenItIsLoud() {
        let activity = Activity([
            SpeakerTurn(voice: "A", start: 0, end: 1.2, embedding: [1, 0]),
            SpeakerTurn(voice: "B", start: 0.8, end: 2, embedding: [0, 1]),
        ], length: 2)
        func voice(loudFrom from: Int, to: Int) -> [Float] {
            (0..<32_000).map { i in Float(sin(Double(i) * 0.3)) * ((from..<to).contains(i) ? 0.5 : 0.001) }
        }

        let names = activity.voices(of: [voice(loudFrom: 16_000, to: 32_000), voice(loudFrom: 0, to: 16_000)], at: .init(start: 0.8, end: 1.2, input: nil), in: .init(start: 0, end: 2, input: nil))

        #expect(names == ["B", "A"])
    }

    /// Shai stops and Niv starts in the same separated voice, while Liron talks in the other.
    @Test func aSeparatedVoiceIsNamedMomentByMoment() {
        let activity = Activity([
            SpeakerTurn(voice: "Shai", start: 0, end: 2, embedding: [1, 0, 0]),
            SpeakerTurn(voice: "Liron", start: 1.5, end: 6, embedding: [0, 1, 0]),
            SpeakerTurn(voice: "Niv", start: 4, end: 6, embedding: [0, 0, 1]),
        ], length: 6)
        let window = OverlapSeparation.Stretch(start: 0, end: 6, input: nil)
        func voice(loud: [Range<Int>]) -> [Float] {
            (0..<96_000).map { i in Float(sin(Double(i) * 0.3)) * (loud.contains { $0.contains(i) } ? 0.5 : 0.001) }
        }
        let separated = [voice(loud: [0..<32_000, 64_000..<96_000]), voice(loud: [24_000..<96_000])]

        let first = activity.voices(of: separated, at: .init(start: 1.5, end: 2, input: nil), in: window)
        let second = activity.voices(of: separated, at: .init(start: 4, end: 6, input: nil), in: window)

        #expect(first == ["Shai", "Liron"])
        #expect(second == ["Niv", "Liron"])
    }

    @Test func withoutTwoPeopleAtOnceNothingIsSeparatedOrTranscribed() async throws {
        let turns = [SpeakerTurn(voice: "S1", start: 0, end: 5, embedding: [1, 0]), SpeakerTurn(voice: "S2", start: 5, end: 9, embedding: [0, 1])]
        let segments = [segment([(1.0, "שלום")], speaker: "Speaker 1")]
        let missing = URL(filePath: "/nonexistent/model.mlpackage")
        let resources = OverlapSeparation.Resources(package: missing, compiled: missing) { _, _ in
            Issue.record("Transcribed")
            return Transcript(language: .hebrew, segments: [])
        }

        let merged = try await OverlapSeparation.apply(
            to: segments, turns: turns, speakers: [], language: .hebrew, length: 10, audio: { _ in [] }, resources: resources
        )

        #expect(merged == segments)
    }

    @Test func transcriptionsOfOneWordMatch() {
        #expect(OverlapSeparation.sameWord("ושנבין", "שנבין"))
        #expect(OverlapSeparation.sameWord("נבין", "שנבין"))
        #expect(OverlapSeparation.sameWord("אז,", "אז"))
        #expect(OverlapSeparation.sameWord("מעולה", "מעולע"))
        #expect(!OverlapSeparation.sameWord("כן", "לא"))
        #expect(!OverlapSeparation.sameWord("go", "rm"))
    }
}
