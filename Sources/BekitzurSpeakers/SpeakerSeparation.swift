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
        return Speakers.combine(timeline: try model.separate(samples), identities: identities, people: people)
    }

    /// Who spoke when in a call recorded as two tracks. The system audio holds the other side, and the microphone the
    /// user's side, but on laptop speakers the microphone also hears the other side, as loud as the system audio.
    /// Separated together, the sides mixed: in a 52-minute call a third of the speech went to a voice from the other side,
    /// and silencing the microphone while the other side spoke didn't change that. So each side is separated on its own:
    /// the system audio, and the microphone with the other side's speech silenced, except where the user talks over them
    /// (`TalkingOver`): on November 2 two short replies said over the other person went to that person.
    ///
    /// Without speech in the system audio, as in a room, the tracks are separated together.
    /// - Parameters:
    ///   - mixed: Both tracks summed.
    ///   - microphone: Lined up with `system`.
    ///   - people: How many people spoke on both sides together, when the user said.
    ///   - keepingTalkingOver: False silences all of the other side's speech, as before November 2, for comparing.
    public static func turns(
        in mixed: [Float],
        microphone: [Float],
        system: [Float],
        people: Int? = nil,
        timeline: Timeline = .nemotron,
        keepingTalkingOver: Bool = true
    ) async throws -> [SpeakerTurn] {
        let otherSide = try await SpeechDetector().speech(in: system)
        guard otherSide.map({ $0.upperBound - $0.lowerBound }).reduce(0, +) >= minimumCallSpeech else {
            return try await turns(in: mixed, people: people, timeline: timeline)
        }
        let over = keepingTalkingOver ? TalkingOver.stretches(microphone: microphone, system: system) : []
        let userSide = silencing(microphone, during: removing(over, from: otherSide))
        let user = userSide.allSatisfy({ abs($0) < 0.0005 }) ? [] : try await turns(in: userSide, timeline: timeline)
        let other = try await turns(in: system, people: people.map { max(1, $0 - Set(user.map(\.voice)).count) }, timeline: timeline)
        return sides(user: user, other: other)
    }

    /// Seconds of speech in the system audio that make a Recording a call.
    static let minimumCallSpeech = 10.0

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

    /// Both sides' turns as one timeline. Each separator names its voices "S1", "S2", …, which aren't the same people.
    static func sides(user: [SpeakerTurn], other: [SpeakerTurn]) -> [SpeakerTurn] {
        let relabeled = user.map { SpeakerTurn(voice: "microphone \($0.voice)", start: $0.start, end: $0.end, embedding: $0.embedding) }
            + other.map { SpeakerTurn(voice: "system \($0.voice)", start: $0.start, end: $0.end, embedding: $0.embedding) }
        return relabeled.sorted { $0.start < $1.start }
    }
}
