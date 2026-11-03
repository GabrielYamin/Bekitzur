import BekitzurDomain
import Testing
@testable import BekitzurSpeakers

private extension SpeakerNaming {
    var name: String? {
        switch self {
        case .named(let name, _), .suggested(let name, _): name
        case .unknown: nil
        }
    }
}

struct SpeakersTests {
    private let guest: [Float] = [1, 0, 0]
    private let user: [Float] = [0, 1, 0]

    private func turn(_ voice: String, _ start: Double, _ end: Double, _ embedding: [Float] = []) -> SpeakerTurn {
        SpeakerTurn(voice: voice, start: start, end: end, embedding: embedding)
    }

    /// The opening of a two-person call: pyannote folds the user's greeting into the other person's voice; the timeline doesn't.
    @Test func combiningKeepsTheTimelineAndTakesEachVoiceFromTheIdentities() {
        let identities = [
            turn("A", 4.4, 5.6, guest), turn("A", 6.8, 9.1, guest), turn("A", 13, 32, guest),
            turn("B", 40, 52, user),
        ]
        let timeline = [
            turn("S0", 4.4, 5.6), turn("S1", 6.9, 9.5), turn("S0", 9.7, 10.6), turn("S1", 13, 34), turn("S0", 39.4, 52),
            turn("S2", 20, 21),
        ]

        let combined = Speakers.combine(timeline: timeline, identities: identities)

        #expect(combined.map(\.voice) == ["B", "A", "B", "A", "B"])
        #expect(combined.map(\.embedding) == [user, guest, user, guest, user])
    }

    /// A call on laptop speakers: the microphone hears the other side as loud as the system audio does.
    @Test func theMicrophoneIsSilencedWhileTheOtherSideSpeaks() {
        let microphone = [Float](repeating: 0.5, count: 3 * 16_000)

        let userSide = SpeakerSeparation.silencing(microphone, during: [0.5...1.0, 2.5...4.0])

        #expect(userSide[..<8_000].allSatisfy { $0 == 0.5 })
        #expect(userSide[8_000..<16_000].allSatisfy { $0 == 0 })
        #expect(userSide[16_000..<40_000].allSatisfy { $0 == 0.5 })
        #expect(userSide[40_000...].allSatisfy { $0 == 0 })
    }

    /// Each side's separator calls its first voice "S1"; on a call they're two people.
    @Test func eachSideOfACallKeepsItsOwnVoices() {
        let user = [turn("S1", 26, 45, user)]
        let other = [turn("S1", 6, 25, guest), turn("S1", 49, 54, guest)]

        let turns = SpeakerSeparation.sides(user: user, other: other)

        #expect(turns.map(\.start) == [6, 26, 49])
        #expect(Speakers.speakers(from: turns).map(\.speechSeconds) == [24, 19])
    }

    /// The timeline hears a fourth voice for 4 of about 900 seconds of speech, and it is one of the other three.
    @Test func aBriefVoiceOnlyTheTimelineHeardIsNoSpeakerInALongConversation() {
        let identities = [turn("Ron", 0, 300, user), turn("Tal", 300, 600, guest), turn("Maya", 600, 900, [0, 0, 1])]
        let timeline = [turn("S0", 0, 300), turn("S1", 300, 600), turn("S2", 600, 900), turn("S3", 950, 954)]

        let combined = Speakers.combine(timeline: timeline, identities: identities)

        #expect(Set(combined.map(\.voice)) == ["Ron", "Tal", "Maya"])
    }

    /// On the other side of a call, pyannote tells three people apart, and the timeline gives two of them one voice.
    @Test func whenTheTimelineHearsTwoPeopleAsOneTheIdentitiesAreKept() {
        let identities = [
            turn("S1", 0, 100, guest), turn("S2", 100, 200, user), turn("S3", 200, 300, [0, 0, 1]), turn("S4", 300, 302, [1, 1, 0]),
        ]
        let timeline = [turn("S0", 0, 100), turn("S1", 100, 200), turn("S1", 200, 300), turn("S2", 300, 301)]

        let combined = Speakers.combine(timeline: timeline, identities: identities)

        #expect(combined.map(\.voice) == ["S1", "S2", "S3", "S4"])
        #expect(Speakers.voices(in: timeline) == 2)
        #expect(Speakers.voices(in: identities) == 3)
    }

    @Test func blipsWithoutAVoiceAreDroppedAndLongerVoicesStayTheirOwn() {
        let identities = [turn("A", 0, 30, guest)]
        let timeline = [turn("S0", 0, 30), turn("S1", 40, 50), turn("S2", 60, 61)]

        let combined = Speakers.combine(timeline: timeline, identities: identities)

        #expect(Set(combined.map(\.voice)).count == 2)
        #expect(combined.map(\.embedding) == [guest, []])
    }

    /// A meeting recorded as a voice memo: pyannote hears the user and one other voice, the timeline hears the user
    /// and two others, and both separators name voices "S1", "S2", ….
    @Test func voicesOnlyTheTimelineHeardStaySeparateEvenWhenLabelsClash() {
        let identities = [turn("S1", 0, 60, user), turn("S2", 60, 120, guest)]
        let timeline = [turn("S2", 0, 60), turn("S0", 60, 90), turn("S1", 90, 120)]

        let combined = Speakers.combine(timeline: timeline, identities: identities)
        let speakers = Speakers.speakers(from: combined)

        #expect(speakers.count == 3)
        #expect(speakers.map(\.speechSeconds) == [60, 30, 30])
        #expect(combined[0].voice == "S1")
    }

    @Test func withTheUsersCountExtraTimelineVoicesJoinTheirClosestIdentity() {
        let identities = [turn("S1", 0, 60, user), turn("S2", 60, 120, guest)]
        let timeline = [turn("S2", 0, 60), turn("S0", 60, 90), turn("S1", 90, 120)]

        let combined = Speakers.combine(timeline: timeline, identities: identities, people: 2)

        #expect(combined.map(\.voice) == ["S1", "S2", "S2"])
        #expect(Speakers.speakers(from: combined).count == 2)
    }

    @Test func aClearMatchIsNamedAndALookalikeIsOnlySuggested() {
        let voiceprints = [Voiceprint(name: "Omer", embedding: user)]
        let clear = Speakers.speakers(from: [turn("A", 0, 10, [0.1, 1, 0]), turn("B", 10, 20, guest)])
        // Two voices that both resemble Omer, as when far voices are faint.
        let alike = Speakers.speakers(from: [turn("A", 0, 10, [0.1, 1, 0]), turn("B", 10, 20, [0.3, 1, 0.1])])

        #expect(Speakers.name(clear, with: voiceprints).map(\.naming.name) == ["Omer", nil])
        if case .named = Speakers.name(clear, with: voiceprints)[0].naming {} else { Issue.record("expected a confident name") }
        if case .suggested("Omer", _) = Speakers.name(alike, with: voiceprints)[0].naming {} else { Issue.record("expected a suggestion") }
    }

    @Test func segmentsSplitWhereTheSpeakerChanges() {
        let words = [("hey", 4.5), ("guest", 4.7), ("how", 5.1), ("are", 5.3), ("you", 5.5),
                     ("hey", 7.0), ("hi", 7.2), ("user", 7.4), ("i'm", 9.8), ("good", 10.0)]
            .map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let segment = TranscriptSegment(start: 0, end: 10.4, text: words.map(\.text).joined(separator: " "), words: words)
        let turns = [turn("G", 4.4, 5.6), turn("P", 6.9, 9.5), turn("G", 9.7, 10.6)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(result.map(\.text) == ["hey guest how are you", "hey hi user", "i'm good"])
        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(result.map(\.start) == [4.5, 7.0, 9.8])
    }

    @Test func wordsBetweenTurnsTakeTheNearestTurnOrTheirNeighbors() {
        let words = [("okay", 3.0), ("so", 6.2), ("then", 20.0)].map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let segment = TranscriptSegment(start: 3, end: 20, text: "okay so then", words: words)
        let turns = [turn("G", 0, 2.5), turn("P", 6.5, 10)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        // "okay" is 0.5 s after the first turn, "so" 0.3 s before the second, and "then" is far from both.
        #expect(result.map(\.text) == ["okay", "so then"])
        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    /// A quick reply: "זה על המק" answers "זה על המק?", and the timeline's turn for the question runs on
    /// into the answer.
    @Test func wordsWhereOneTurnRunsIntoTheNextGoToTheNewSpeaker() {
        let words = [("על", 5.76), ("המק?", 5.99), ("זה", 6.26), ("על", 6.42), ("המק,", 6.76)]
            .map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let segment = TranscriptSegment(start: 5.7, end: 6.9, text: "על המק? זה על המק,", words: words)
        let turns = [turn("Them", 3.92, 6.88), turn("Omer", 6.24, 9.44)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(result.map(\.text) == ["על המק?", "זה על המק,"])
        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func aShortReplyInsideALongTurnDoesntTakeTheLongTurnsWords() {
        let words = [("so", 9.0), ("then", 10.2), ("we", 11.5)].map { TranscriptWord(start: $0.1, end: $0.1, text: $0.0) }
        let segment = TranscriptSegment(start: 9, end: 11.6, text: "so then we", words: words)
        let turns = [turn("Long", 0, 20), turn("Reply", 10.0, 10.5)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(result.map(\.speaker) == ["Speaker 1"])
    }

    @Test func aWordTimedAsSecondsLongIsPlacedByItsStart() {
        let words = [TranscriptWord(start: 24.52, end: 24.92, text: "אחרת?"), TranscriptWord(start: 25.34, end: 28.44, text: "אינטגרציה")]
        let segment = TranscriptSegment(start: 24.5, end: 28.5, text: "אחרת? אינטגרציה", words: words)
        let turns = [turn("Omer", 22.72, 24.80), turn("Them", 26.88, 28.56)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(result.map(\.speaker) == ["Speaker 1"])
    }

    @Test func aSegmentWithoutWordsGoesToWhoeverTalksMost() {
        let segment = TranscriptSegment(start: 0, end: 10, text: "שלום לכולם")
        let turns = [turn("G", 0, 3), turn("P", 3, 10)]

        let result = Speakers.attribute([segment], turns: turns, speakers: Speakers.speakers(from: turns))

        #expect(result.map(\.speaker) == ["Speaker 2"])
        #expect(result.map(\.text) == ["שלום לכולם"])
    }

    /// A voice without a fingerprint gets one from where it talks alone, so no one else's voice mixes in.
    @Test func aVoicesOwnSpeechLeavesOutWhereOthersTalkAndBriefRemnants() {
        let turns = [turn("A", 0, 5), turn("B", 1, 2, guest), turn("A", 6, 6.3), turn("B", 4.8, 7, guest)]

        #expect(SpeakerSeparation.alone("A", in: turns) == [0...1, 2...4.8])
    }
}
