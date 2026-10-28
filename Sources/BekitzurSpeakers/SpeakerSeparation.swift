import Foundation

/// Who spoke when in a whole Recording.
///
/// Sortformer follows quick exchanges that the pyannote pipeline folds into the surrounding speaker, but it has no
/// embeddings and at most four voices. So Sortformer's timeline is used with pyannote's embeddings, which Voiceprints
/// are made of, unless pyannote hears more than four voices.
///
/// When the user says how many people spoke and pyannote hears a different number, pyannote is held to that number
/// and its own timeline is used: Sortformer can't be told how many voices to find. In a 32-minute meeting recorded as a
/// voice memo, where two of the three people were far from the microphone, pyannote heard two voices and Sortformer
/// four; held to three, pyannote told all three apart.
public enum SpeakerSeparation {
    public static func turns(in samples: [Float], people: Int? = nil) async throws -> [SpeakerTurn] {
        let pyannote = SpeakerSeparator()
        try await pyannote.prepare()
        let identities = try await pyannote.separate(samples)
        let minimumVoiceSeconds = Speakers.minimumVoiceSeconds(amid: identities)
        let voices = Dictionary(grouping: identities, by: \.voice)
            .filter { $0.value.map(\.duration).reduce(0, +) >= minimumVoiceSeconds }
            .count

        if let people, people != voices {
            let held = SpeakerSeparator(people: people)
            try await held.prepare()
            return try await held.separate(samples)
        }
        guard voices <= SortformerSeparator.maximumVoices else { return identities }

        let sortformer = SortformerSeparator()
        try await sortformer.prepare()
        return Speakers.combine(timeline: try sortformer.separate(samples), identities: identities, people: people)
    }

    /// Who spoke when in a call recorded as two tracks. The system audio holds the other side, and the microphone the
    /// user's side, but on laptop speakers the microphone also hears the other side, as loud as the system audio.
    /// Separated together, the sides mixed: in a 52-minute call a third of the speech went to a voice from the other side,
    /// and silencing the microphone while the other side spoke didn't change that. So each side is separated on its own:
    /// the system audio, and the microphone with the other side's speech silenced. Words the user says while someone on
    /// the other side speaks go to that person.
    ///
    /// Without speech in the system audio, as in a room, the tracks are separated together.
    /// - Parameters:
    ///   - mixed: Both tracks summed.
    ///   - people: How many people spoke on both sides together, when the user said.
    public static func turns(in mixed: [Float], microphone: [Float], system: [Float], people: Int? = nil) async throws -> [SpeakerTurn] {
        let otherSide = try await SpeechDetector().speech(in: system)
        guard otherSide.map({ $0.upperBound - $0.lowerBound }).reduce(0, +) >= minimumCallSpeech else {
            return try await turns(in: mixed, people: people)
        }
        let userSide = silencing(microphone, during: otherSide)
        let user = userSide.allSatisfy({ abs($0) < 0.0005 }) ? [] : try await turns(in: userSide)
        let other = try await turns(in: system, people: people.map { max(1, $0 - Set(user.map(\.voice)).count) })
        return sides(user: user, other: other)
    }

    /// Seconds of speech in the system audio that make a Recording a call.
    static let minimumCallSpeech = 10.0

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
