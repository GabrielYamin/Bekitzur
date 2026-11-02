import Foundation

/// Who spoke when in a whole Recording.
///
/// A timeline model follows quick exchanges that the pyannote pipeline folds into the surrounding speaker, but it has no
/// embeddings. So its timeline is used with pyannote's embeddings, which Voiceprints are made of, unless pyannote hears
/// more voices than the timeline model can tell apart, or than it heard (``Speakers/combine(timeline:identities:people:)``).
///
/// The timeline model is NVIDIA's Nemotron 3 Diarization, for up to eight voices. It took over from Sortformer, which
/// tells apart four: on the other side of a weekly call it heard the three people pyannote did, where Sortformer gave two
/// of them one voice; in an in-room conversation it heard the two pyannote did, where Sortformer split the user in two;
/// and elsewhere the two gave the same Speakers.
///
/// When the user says how many people spoke and pyannote hears a different number, pyannote is held to that number
/// and its own timeline is used: the timeline model can't be told how many voices to find. In a 32-minute meeting
/// recorded as a voice memo, where two of the three people were far from the microphone, pyannote heard two voices and
/// Sortformer four; held to three, pyannote told all three apart.
public enum SpeakerSeparation {
    /// The model that says who spoke when, which pyannote's voices are matched to.
    public enum Timeline: String, Sendable, CaseIterable {
        case sortformer
        /// NVIDIA's Nemotron 3 Diarization, Sortformer's successor, for up to eight voices.
        case nemotron

        /// The model, loaded. Nemotron's downloads the first time; an install from before, which has Sortformer's, uses
        /// that until then, and deletes it once Nemotron's is in place.
        func load() async throws -> (maximumVoices: Int, separate: ([Float]) throws -> [SpeakerTurn]) {
            switch self {
            case .sortformer:
                let sortformer = SortformerSeparator()
                try await sortformer.prepare()
                return (SortformerSeparator.maximumVoices, sortformer.separate)
            case .nemotron:
                let nemotron = NemotronSeparator()
                do {
                    try await nemotron.prepare()
                } catch {
                    guard SpeakerModels.hasSortformer else { throw error }
                    return try await Timeline.sortformer.load()
                }
                SpeakerModels.removeReplaced()
                return (NemotronSeparator.maximumVoices, nemotron.separate)
            }
        }
    }

    public static func turns(in samples: [Float], people: Int? = nil, timeline: Timeline = .nemotron) async throws -> [SpeakerTurn] {
        let pyannote = SpeakerSeparator()
        try await pyannote.prepare()
        let identities = try await pyannote.separate(samples)
        let voices = Speakers.voices(in: identities)

        if let people, people != voices {
            let held = SpeakerSeparator(people: people)
            try await held.prepare()
            return try await held.separate(samples)
        }
        let model = try await timeline.load()
        guard voices <= model.maximumVoices else { return identities }
        let combined = Speakers.combine(timeline: try model.separate(samples), identities: identities, people: people)
        return await fingerprinted(combined, in: samples, with: pyannote)
    }

    /// Voices only the timeline model heard come without a fingerprint, so they can't be recognized next time: on
    /// November 2, in 34 seconds of two people in a room, pyannote heard one voice where Nemotron heard both. Each gets one
    /// from pyannote on that voice's own speech, the stretches where no other voice talks put together, so it's comparable
    /// with the Voiceprints, which come from pyannote too.
    static func fingerprinted(_ turns: [SpeakerTurn], in samples: [Float], with pyannote: SpeakerSeparator) async -> [SpeakerTurn] {
        var fingerprints: [String: [Float]] = [:]
        for voice in Set(turns.filter { $0.embedding.isEmpty }.map(\.voice)) {
            var audio: [Float] = []
            for stretch in alone(voice, in: turns) {
                let start = max(0, Int(stretch.lowerBound * 16_000)), end = min(samples.count, Int(stretch.upperBound * 16_000))
                if start < end { audio += samples[start..<end] + [Float](repeating: 0, count: 3_200) }
            }
            guard audio.count >= 3 * 16_000, let heard = try? await pyannote.separate(audio) else { continue }
            let main = Dictionary(grouping: heard, by: \.voice).values.max { $0.map(\.duration).reduce(0, +) < $1.map(\.duration).reduce(0, +) }
            if let main, !Speakers.weightedMean(main).isEmpty { fingerprints[voice] = Speakers.weightedMean(main) }
        }
        return turns.map { turn in
            guard turn.embedding.isEmpty, let fingerprint = fingerprints[turn.voice] else { return turn }
            return SpeakerTurn(voice: turn.voice, start: turn.start, end: turn.end, embedding: fingerprint, input: turn.input)
        }
    }

    /// Where `voice` talks and no other voice does, in stretches of at least 0.4 seconds.
    static func alone(_ voice: String, in turns: [SpeakerTurn]) -> [ClosedRange<Double>] {
        let others = turns.filter { $0.voice != voice }.map { $0.start...$0.end }
        return removing(others, from: turns.filter { $0.voice == voice }.map { $0.start...$0.end }).filter { $0.upperBound - $0.lowerBound >= 0.4 }
    }

    /// Who spoke when in a call recorded as two tracks. The system audio holds the other side, and the microphone the
    /// room, but on laptop speakers the microphone also hears the other side, as loud as the system audio. Separated
    /// together, the sides mixed: in a 52-minute call a third of the speech went to a voice from the other side, and
    /// silencing the microphone while the other side spoke didn't change that, but lost what the user said over them.
    /// So each input is separated on its own, the microphone with the other side taken out (`EchoCanceller`), and a voice
    /// heard in both is one person (`sides(user:other:)`).
    ///
    /// Without speech in the system audio, as in a room, the tracks are separated together.
    /// - Parameters:
    ///   - mixed: Both tracks summed.
    ///   - microphone: Lined up with `system`, and without the other side when they came through speakers.
    ///   - people: How many people spoke on both sides together, when the user said.
    ///   - silencingOtherSide: True for a microphone that still has the other side: it's silenced while they talk,
    ///     except where the user talks over them (`TalkingOver`), as before, for comparing.
    public static func turns(
        in mixed: [Float],
        microphone: [Float],
        system: [Float],
        people: Int? = nil,
        timeline: Timeline = .nemotron,
        silencingOtherSide: Bool = false
    ) async throws -> [SpeakerTurn] {
        let otherSide = try await SpeechDetector().speech(in: system)
        guard otherSide.map({ $0.upperBound - $0.lowerBound }).reduce(0, +) >= minimumCallSpeech else {
            return try await turns(in: mixed, people: people, timeline: timeline)
        }
        let userSide = silencingOtherSide
            ? silencing(microphone, during: removing(TalkingOver.stretches(microphone: microphone, system: system), from: otherSide))
            : microphone
        let user = userSide.allSatisfy({ abs($0) < 0.0005 }) ? [] : try await turns(in: userSide, timeline: timeline)
        let other = try await turns(in: system, people: people.map { max(1, $0 - Set(user.map(\.voice)).count) }, timeline: timeline)
        return sides(user: user, other: other)
    }

    /// Seconds of speech in the system audio that make a Recording a call.
    static let minimumCallSpeech = 10.0

    /// Whether the system audio has enough speech for the Recording to be a call, whose tracks are separated and
    /// transcribed each on its own.
    public static func isCall(system: [Float]) async throws -> Bool {
        try await SpeechDetector().speech(in: system).map { $0.upperBound - $0.lowerBound }.reduce(0, +) >= minimumCallSpeech
    }

    /// `stretches` without the parts in `holes`.
    static func removing(_ holes: [ClosedRange<Double>], from stretches: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        stretches.flatMap { stretch in
            holes.filter { $0.overlaps(stretch) }.reduce([stretch]) { pieces, hole in
                pieces.flatMap { piece -> [ClosedRange<Double>] in
                    guard hole.overlaps(piece) else { return [piece] }
                    return (piece.lowerBound < hole.lowerBound ? [piece.lowerBound...hole.lowerBound] : [])
                        + (hole.upperBound < piece.upperBound ? [hole.upperBound...piece.upperBound] : [])
                }
            }
        }
    }

    /// The samples, 16 kHz, with silence in the given stretches.
    static func silencing(_ samples: [Float], during stretches: [ClosedRange<Double>]) -> [Float] {
        var result = samples
        for stretch in stretches {
            let start = min(result.count, max(0, Int(stretch.lowerBound * 16_000)))
            let end = min(result.count, max(start, Int((stretch.upperBound * 16_000).rounded(.up))))
            for i in start..<end { result[i] = 0 }
        }
        return result
    }

    /// Both sides' turns as one timeline. Each separator names its voices "S1", "S2", …, which aren't the same people,
    /// but a voice in the microphone whose fingerprint is a voice in the system audio is that person: someone in the
    /// room who also joined the call, or what's left of the other side in the microphone. On four calls, voices left
    /// from the other side matched theirs at 0.64 to 0.96, and the user matched no one on the other side above 0.36.
    static func sides(user: [SpeakerTurn], other: [SpeakerTurn]) -> [SpeakerTurn] {
        let otherVoices = Dictionary(grouping: other, by: \.voice).mapValues(Speakers.weightedMean)
        let same = Dictionary(grouping: user, by: \.voice).compactMapValues { turns -> String? in
            let fingerprint = Speakers.weightedMean(turns)
            let best = otherVoices.map { ($0.key, Speakers.cosine(fingerprint, $0.value)) }.max { $0.1 < $1.1 }
            return best.flatMap { $0.1 >= sameVoice ? $0.0 : nil }
        }
        let relabeled = user.map {
            SpeakerTurn(voice: same[$0.voice].map { "system \($0)" } ?? "microphone \($0.voice)", start: $0.start, end: $0.end, embedding: $0.embedding, input: .microphone)
        } + other.map { SpeakerTurn(voice: "system \($0.voice)", start: $0.start, end: $0.end, embedding: $0.embedding, input: .systemAudio) }
        return relabeled.sorted { $0.start < $1.start }
    }

    /// The fingerprint similarity from which a voice in each input is one person.
    static let sameVoice: Float = 0.55
}
