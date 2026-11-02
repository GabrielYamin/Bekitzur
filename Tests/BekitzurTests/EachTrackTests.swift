import BekitzurDomain
import BekitzurPipeline
import Testing
@testable import BekitzurSpeakers

/// A call's tracks transcribed each on its own, then put together.
struct EachTrackTests {
    private func segment(_ words: [(Double, String)], input: RecordingInput? = nil) -> TranscriptSegment {
        let timed = words.map { TranscriptWord(start: $0.0, end: $0.0 + 0.3, text: $0.1) }
        return TranscriptSegment(start: timed[0].start, end: timed.last!.end, text: timed.map(\.text).joined(separator: " "), words: timed, input: input)
    }

    /// November 2: the user said "בא לי לישון" while the other person spoke, and only the user's words were written.
    @Test func bothTracksWordsAreKeptEachTaggedWithItsTrack() {
        let system = Transcript(language: .hebrew, segments: [segment([(5.6, "גם"), (5.8, "לי,")]), segment([(7.2, "אבל"), (7.5, "יש"), (7.8, "קפה")])])
        let microphone = Transcript(language: .hebrew, segments: [segment([(5.66, "בא"), (5.8, "לי"), (6.0, "לישון")])])

        let merged = ConversationProcessor.merging(microphone: microphone, system: system, microphoneSpeech: [5.6...6.4])

        #expect(merged.segments.map(\.text) == ["גם לי,", "בא לי לישון", "אבל יש קפה"])
        #expect(merged.segments.map(\.input) == [.systemAudio, .microphone, .systemAudio])
    }

    @Test func whatsLeftOfTheOtherSideInTheMicrophoneGoes() {
        let system = Transcript(language: .hebrew, segments: [segment([(10.0, "סוג"), (10.3, "של"), (10.6, "ראש"), (10.9, "הממשלה")])])
        let microphone = Transcript(language: .hebrew, segments: [segment([(9.0, "כן"), (10.05, "סוג"), (10.32, "של"), (10.7, "ראש"), (12.0, "הבנתי")])])

        let merged = ConversationProcessor.merging(microphone: microphone, system: system, microphoneSpeech: [8.9...12.4])

        #expect(merged.segments.filter { $0.input == .microphone }.flatMap { $0.words ?? [] }.map(\.text) == ["כן", "הבנתי"])
    }

    /// November 2: speech recognition wrote "תודה רבה לך, אדוני היושב-ראש" where the microphone was silenced.
    @Test func microphoneWordsAwayFromItsSpeechGo() {
        let system = Transcript(language: .hebrew, segments: [segment([(55.6, "וקצת"), (56.0, "אג'נדה,"), (57.7, "וכל")])])
        let microphone = Transcript(language: .hebrew, segments: [
            segment([(57.42, "תודה"), (57.68, "רבה"), (57.68, "לך,")]),
            segment([(64.17, "מה"), (64.5, "הבעיה?")]),
        ])

        let merged = ConversationProcessor.merging(microphone: microphone, system: system, microphoneSpeech: [64.1...65.0])

        #expect(merged.segments.filter { $0.input == .microphone }.map(\.text) == ["מה הבעיה?"])
    }

    @Test func aStretchFromOneTrackGoesToAVoiceHeardThere() {
        let turns = [
            SpeakerTurn(voice: "system S1", start: 0, end: 10, embedding: [1, 0], input: .systemAudio),
            SpeakerTurn(voice: "microphone S1", start: 4, end: 6, embedding: [0, 1], input: .microphone),
        ]
        let speakers = Speakers.speakers(from: turns)

        let attributed = Speakers.attribute([segment([(4.5, "אני"), (5.0, "לא")], input: .systemAudio), segment([(4.5, "בא"), (5.0, "לי")], input: .microphone)], turns: turns, speakers: speakers)

        #expect(attributed.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    /// November 1: what the microphone made of the other side's voice came out as words of theirs, misheard.
    @Test func microphoneWordsOfAVoiceInTheSystemAudioAreLeftOut() {
        let turns = [
            SpeakerTurn(voice: "system S1", start: 0, end: 10, embedding: [1, 0], input: .systemAudio),
            SpeakerTurn(voice: "system S1", start: 2, end: 3, embedding: [1, 0], input: .microphone),
            SpeakerTurn(voice: "microphone S1", start: 6, end: 7, embedding: [0, 1], input: .microphone),
        ]
        let segments = [segment([(2.2, "שתי"), (2.5, "האוות")], input: .microphone), segment([(2.2, "שתי"), (2.5, "הערות")], input: .systemAudio), segment([(6.2, "בדיוק")], input: .microphone)]

        let attributed = Speakers.attribute(segments, turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(attributed.map(\.text) == ["שתי הערות", "בדיוק"])
        #expect(attributed.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }
}
