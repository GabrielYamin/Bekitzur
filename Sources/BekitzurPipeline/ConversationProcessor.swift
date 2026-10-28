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

    /// The tracks with the microphone played `seconds` later, and their sum.
    public func delayingMicrophone(by seconds: Double) -> (tracks: CallTracks, mixed: [Float]) {
        let delayed = [Float](repeating: 0, count: Int((seconds * AudioLoader.sampleRate).rounded())) + microphone
        var mixed = [Float](repeating: 0, count: max(delayed.count, system.count))
        for i in delayed.indices { mixed[i] += delayed[i] }
        for i in system.indices { mixed[i] += system[i] }
        return (CallTracks(microphone: delayed, system: system), mixed)
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
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) async throws -> ProcessedConversation {
        var transcript: Transcript
        if let existing, existing.language == language {
            transcript = existing
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
