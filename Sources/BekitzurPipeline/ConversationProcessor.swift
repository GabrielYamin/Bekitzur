import BekitzurAudio
import BekitzurDomain
import BekitzurNotes
import BekitzurSpeakers
import BekitzurTranscription
import BekitzurVocabulary
import Foundation

public enum ProcessingStep: String, Sendable {
    case transcribing = "Transcribing"
    case recognizingSpeakers = "Recognizing speakers"
    case separatingVoices = "Separating people who talk at once"
    case checkingTerms = "Checking English terms"
    case writingNotes = "Writing Notes"
}

public struct MixedAudio: Sendable {
    /// 16 kHz mono.
    public let samples: [Float]
    /// Tracks that exist but recorded only silence, like system audio when the permission was denied.
    public let silentTracks: [URL]
    /// Each track, 16 kHz mono.
    public let tracks: [URL: [Float]]
}

/// The two tracks of a call, 16 kHz mono, for separating each side's Speakers on its own.
public struct CallTracks: Sendable {
    public let microphone: [Float]
    public let system: [Float]

    public init(microphone: [Float], system: [Float]) {
        self.microphone = microphone
        self.system = system
    }

    /// How much later to play the microphone so it lines up with the system audio, from the copy of the system audio
    /// that speakers put in it; nil without one (`TrackAlignment`).
    public var measuredMicrophoneDelay: Double? {
        TrackAlignment.microphoneDelay(microphone: microphone, system: system)
    }

    /// How much later to play the system audio along the call so the other side lines up with the microphone's copy
    /// (`TrackAlignment`); empty without one.
    public var measuredSystemAudioDelays: [TrackDelay] {
        TrackAlignment.systemAudioDelays(microphone: microphone, system: system)
    }

    /// The tracks with the microphone played `seconds` later, and their sum.
    public func delayingMicrophone(by seconds: Double) -> (tracks: CallTracks, mixed: [Float]) {
        let delayed = [Float](repeating: 0, count: Int((seconds * AudioLoader.sampleRate).rounded())) + microphone
        return Self.mixing(microphone: delayed, system: system)
    }

    /// The tracks with the system audio played as `delays` say, and their sum.
    public func placingSystemAudio(by delays: [TrackDelay]) -> (tracks: CallTracks, mixed: [Float]) {
        Self.mixing(microphone: microphone, system: TrackAlignment.placing(system, by: delays))
    }

    /// The tracks with the speakers' copy of the other side taken out of the microphone, and what's left of it silenced
    /// where the microphone has no speech of its own (`EchoCanceller`), their sum, and where the microphone has speech.
    public func removingEcho() -> (tracks: CallTracks, mixed: [Float], microphoneSpeech: [ClosedRange<Double>]) {
        let echo = EchoCanceller.cancel(microphone: microphone, system: system)
        let lined = Self.mixing(microphone: echo.ownSpeechOnly(), system: system)
        return (lined.tracks, lined.mixed, echo.speech())
    }

    private static func mixing(microphone: [Float], system: [Float]) -> (tracks: CallTracks, mixed: [Float]) {
        var mixed = [Float](repeating: 0, count: max(microphone.count, system.count))
        for i in microphone.indices { mixed[i] += microphone[i] }
        for i in system.indices { mixed[i] += system[i] }
        return (CallTracks(microphone: microphone, system: system), mixed)
    }
}

public enum ProcessingError: Error, CustomStringConvertible {
    case noAudio
    case noSpeech
    case transcriptionStopped

    public var description: String {
        switch self {
        case .noAudio: "The Recording has no audio."
        case .transcriptionStopped: "The speech model stopped while transcribing this Recording. Try transcribing it again."
        case .noSpeech: "No one spoke in the voice sample. Try again a little closer to the microphone."
        }
    }
}

/// Runs the engine on a Recording: transcription, then Speakers, then Notes, with one model in memory at a time.
public enum ConversationProcessor {
    /// How much later to play a call's microphone track so it lines up with its system audio track (`TrackAlignment`);
    /// nil without a copy of the system audio in the microphone.
    public static func microphoneDelay(microphone: URL, system: URL) throws -> Double? {
        TrackAlignment.microphoneDelay(microphone: try AudioLoader.loadMono16k(microphone), system: try AudioLoader.loadMono16k(system))
    }

    /// How much later to play a call's system audio along the call (`TrackAlignment.systemAudioDelays`), with the
    /// microphone played `microphoneDelay` seconds later as it is everywhere else.
    public static func systemAudioDelays(microphone: URL, system: URL, microphoneDelay: Double) throws -> [TrackDelay] {
        let tracks = CallTracks(microphone: try AudioLoader.loadMono16k(microphone), system: try AudioLoader.loadMono16k(system))
        return (microphoneDelay > 0 ? tracks.delayingMicrophone(by: microphoneDelay).tracks : tracks).measuredSystemAudioDelays
    }

    /// A call's tracks transcribed each on its own, as one Transcript: each stretch tagged with its track, so its words go
    /// to the voices heard there, and without what's left of the other side in the microphone: words that repeat the
    /// system audio's within 0.4 seconds, next to another that does, since two people can say the same word at once.
    /// Nor the microphone's words more than 0.25 seconds from its speech, which speech recognition wrote into silence.
    /// Transcribed together, two people talking at once come out as one, and one person's words are lost.
    public static func merging(microphone: Transcript, system: Transcript, microphoneSpeech: [ClosedRange<Double>]) -> Transcript {
        let heard = system.segments.flatMap { $0.words ?? [] }.map { (start: $0.start, text: normalized($0.text)) }
        let spoken = { (start: Double, end: Double) in microphoneSpeech.contains { $0.lowerBound <= end + 0.25 && start - 0.25 <= $0.upperBound } }
        let microphoneSegments = microphone.segments.compactMap { segment -> TranscriptSegment? in
            var segment = segment
            segment.input = .microphone
            guard let words = segment.words else { return spoken(segment.start, segment.end) ? segment : nil }
            let repeats = words.map { word in
                let text = normalized(word.text)
                return !text.isEmpty && heard.contains { abs($0.start - word.start) < 0.4 && $0.text == text }
            }
            let kept = words.indices.filter { i in
                // A word's last token can be timed seconds late, so no word counts as longer than 0.6 seconds.
                spoken(words[i].start, min(words[i].end, words[i].start + 0.6))
                    && !(repeats[i] && ((i > 0 && repeats[i - 1]) || (i + 1 < words.count && repeats[i + 1])))
            }.map { words[$0] }
            guard let first = kept.first, let last = kept.last else { return nil }
            if kept.count < words.count {
                segment.words = kept
                segment.text = kept.map(\.text).joined(separator: " ")
                segment.start = first.start
                segment.end = last.end
            }
            return segment
        }
        let systemSegments = system.segments.map { segment -> TranscriptSegment in
            var segment = segment
            segment.input = .systemAudio
            return segment
        }
        return Transcript(language: system.language, segments: (microphoneSegments + systemSegments).sorted { $0.start < $1.start })
    }

    /// Where a call's microphone has speech of its own: above what's left of the other side and the room's noise
    /// (`CallTracks.removingEcho`), and speech to the speech detector too, since keystrokes are loud enough for the first
    /// and speech recognition writes words over them ("Hvað er það?"). Without the detector, the first alone.
    /// - Parameter microphone: The microphone without the other side (`CallTracks.removingEcho`).
    public static func microphoneSpeech(_ ownSpeech: [ClosedRange<Double>], in microphone: [Float]) async -> [ClosedRange<Double>] {
        // Surer than live transcription asks for (0.5), at which a burst of keystrokes passes as speech.
        guard let detected = try? await SpeechDetector().speech(in: microphone, threshold: 0.7) else { return ownSpeech }
        return overlaps(ownSpeech, detected)
    }

    /// Where stretches of the one and of the other overlap.
    static func overlaps(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        a.flatMap { x in
            b.compactMap { y -> ClosedRange<Double>? in
                let lower = max(x.lowerBound, y.lowerBound), upper = min(x.upperBound, y.upperBound)
                return lower <= upper ? lower...upper : nil
            }
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A word without case or punctuation, for telling whether two tracks heard the same one.
    static func normalized(_ word: String) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Loads the tracks that exist and sums them into one signal.
    public static func loadMixed(_ tracks: [URL]) throws -> MixedAudio {
        var mixed: [Float] = []
        var silent: [URL] = []
        var loaded: [URL: [Float]] = [:]
        for url in tracks where FileManager.default.fileExists(atPath: url.path) {
            let track = try AudioLoader.loadMono16k(url)
            if track.allSatisfy({ abs($0) < 0.0005 }) { silent.append(url) }
            if track.count > mixed.count { mixed += [Float](repeating: 0, count: track.count - mixed.count) }
            for i in track.indices { mixed[i] += track[i] }
            loaded[url] = track
        }
        guard !mixed.isEmpty else { throw ProcessingError.noAudio }
        return MixedAudio(samples: mixed, silentTracks: silent, tracks: loaded)
    }

    /// - Parameters:
    ///   - people: How many people spoke, when the user said.
    ///   - call: The tracks of a call, to separate each side's Speakers on its own.
    ///   - transcript: A Transcript already made in this language, to separate Speakers again without transcribing.
    ///   - flags: The user's marks on that Transcript; their fixes go into the Notes.
    ///   - vocabulary: The user's own terms and taught spellings, on top of the built-in terms.
    ///   - separation: What separating people who talk at once needs, when its model is downloaded.
    public static func process(
        _ samples: [Float],
        date: Date,
        language: ConversationLanguage,
        voiceprints: [Voiceprint],
        people: Int? = nil,
        call: CallTracks? = nil,
        transcript existing: Transcript? = nil,
        flags: TranscriptFlags = TranscriptFlags(),
        vocabulary: Vocabulary = Vocabulary(),
        separation: OverlapSeparation.Resources? = nil,
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) async throws -> ProcessedConversation {
        var transcript: Transcript
        if let existing, existing.language == language {
            transcript = existing
            transcript.segments.removeAll { $0.separated == true }
        } else {
            progress(.transcribing)
            transcript = try Transcript(
                language: language,
                segments: Transcriber(modelURL: BekitzurPaths.speechModel(for: language)).transcribe(samples, language: language)
            )
        }

        progress(.recognizingSpeakers)
        let turns = if let call {
            try await SpeakerSeparation.turns(in: samples, microphone: call.microphone, system: call.system, people: people)
        } else {
            try await SpeakerSeparation.turns(in: samples, people: people)
        }
        let speakers = Speakers.name(Speakers.speakers(from: turns), with: voiceprints)
        transcript.segments = Speakers.attribute(transcript.segments, turns: turns, speakers: speakers)
        if let separation {
            progress(.separatingVoices)
            transcript.segments = try await OverlapSeparation.apply(
                to: transcript.segments,
                turns: turns,
                speakers: speakers,
                language: language,
                length: Double(samples.count) / 16_000,
                audio: { input in
                    switch input {
                    case .microphone: call?.microphone ?? samples
                    case .systemAudio: call?.system ?? samples
                    case nil: samples
                    }
                },
                resources: separation
            )
        }

        let separated = ProcessedConversation(
            transcript: transcript,
            speakers: speakers.map {
                ConversationSpeaker(label: $0.label, speechSeconds: $0.speechSeconds, embedding: $0.centroid, naming: $0.naming)
            },
            turns: [],
            notes: Notes()
        )
        return try rewriteNotes(separated, flags: flags, vocabulary: vocabulary, date: date, language: language, progress: progress)
    }

    /// Checks the Transcript's English terms against the Vocabulary, then writes the Notes from it with the user's
    /// fixes applied. Needs only the language model, not the audio.
    public static func rewriteNotes(
        _ result: ProcessedConversation,
        flags: TranscriptFlags,
        vocabulary: Vocabulary,
        date: Date,
        language: ConversationLanguage,
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) throws -> ProcessedConversation {
        var result = result
        let model = try LanguageModel(modelURL: BekitzurPaths.languageModel)
        if language == .hebrew {
            progress(.checkingTerms)
            result.transcript = VocabularyRewriter(vocabulary: vocabulary, model: model).rewrite(result.transcript).0
        }
        progress(.writingNotes)
        let turns = NotesWriter.turns(from: result.transcript.applying(flags))
        result.notes = try NotesWriter(model: model).write(turns: turns, date: date, language: language).notes
        result.turns = turns
        result.notesFixes = flags.fixes
        result.separationChangedNotes = nil
        return result
    }

    /// Learns a Participant's Voiceprint from a recording of them talking.
    public static func voiceprint(named name: String, from url: URL) async throws -> Voiceprint {
        let separator = SpeakerSeparator()
        try await separator.prepare()
        let turns = try await separator.separate(AudioLoader.loadMono16k(url))
        guard let voiceprint = Speakers.voiceprint(named: name, from: turns) else { throw ProcessingError.noSpeech }
        return voiceprint
    }
}
