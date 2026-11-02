import Foundation

/// One word of a Transcript with its timing, in seconds from the start of the Recording.
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// What speech recognition wrote, when the Vocabulary rewrote it ("רדיס" for "Redis").
    public var transcribed: String?

    public init(start: Double, end: Double, text: String, transcribed: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.transcribed = transcribed
    }
}

/// Which of a call's two tracks something was heard in.
public enum RecordingInput: String, Codable, Sendable, Hashable {
    case microphone, systemAudio
}

/// A stretch of a Transcript with its timing, in seconds from the start of the Recording.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// The Speaker label, once speaker separation has run.
    public var speaker: String?
    /// The words with their own timing, so a segment can be split where the Speaker changes.
    public var words: [TranscriptWord]?
    /// The track it was transcribed from, when a call's tracks are transcribed each on its own; its words go to a voice
    /// heard there.
    public var input: RecordingInput?

    public init(start: Double, end: Double, text: String, speaker: String? = nil, words: [TranscriptWord]? = nil, input: RecordingInput? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
        self.input = input
    }

    /// The segment with its times and its words' times moved later by `seconds`, for a stretch transcribed on its own.
    public func shifted(by seconds: Double) -> TranscriptSegment {
        var shifted = self
        shifted.start += seconds
        shifted.end += seconds
        shifted.words = words?.map { word in
            var word = word
            word.start += seconds
            word.end += seconds
            return word
        }
        return shifted
    }
}

/// The Transcript written while a Conversation is recorded, about half a minute behind. Complete once the recording has
/// stopped and its last stretch is transcribed; until then, processing transcribes the recorded files instead.
public struct LiveTranscript: Codable, Sendable, Equatable {
    public var transcript: Transcript
    public var complete: Bool

    public init(transcript: Transcript, complete: Bool) {
        self.transcript = transcript
        self.complete = complete
    }
}

/// The two languages a Conversation can be in.
public enum ConversationLanguage: String, Codable, Sendable, CaseIterable {
    case hebrew = "he"
    case english = "en"

    public var name: String {
        switch self {
        case .hebrew: "Hebrew"
        case .english: "English"
        }
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var language: ConversationLanguage
    public var segments: [TranscriptSegment]

    public init(language: ConversationLanguage, segments: [TranscriptSegment]) {
        self.language = language
        self.segments = segments
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// The Transcript with the user's marks applied: corrected words say what was said, and words said by another
    /// Speaker move to that Speaker, splitting segments where the Speaker changes.
    public func applying(_ flags: TranscriptFlags) -> Transcript {
        guard !flags.words.isEmpty else { return self }
        let speakers = Array(Set(segments.compactMap(\.speaker))).sorted()
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard let words = segment.words, words.contains(where: { flags.flag(for: $0) != nil }) else {
                result.append(segment)
                continue
            }
            var run: [TranscriptWord] = []
            var runSpeaker: String?
            func finishRun() {
                guard let first = run.first, let last = run.last else { return }
                result.append(TranscriptSegment(
                    start: first.start,
                    end: last.end,
                    text: run.map(\.text).joined(separator: " "),
                    speaker: runSpeaker,
                    words: run,
                    input: segment.input
                ))
                run = []
            }
            for word in words {
                var shown = word
                shown.text = flags.text(of: word)
                // The rest of a phrase corrected together, which its first word says.
                guard !shown.text.isEmpty else { continue }
                let speaker = flags.speaker(of: word, transcribedAs: segment.speaker, among: speakers)
                if !run.isEmpty, speaker != runSpeaker { finishRun() }
                runSpeaker = speaker
                run.append(shown)
            }
            finishRun()
        }
        return Transcript(language: language, segments: result)
    }
}
