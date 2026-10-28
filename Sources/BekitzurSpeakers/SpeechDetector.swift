import FluidAudio
import Foundation

/// Where people speak in a stretch of audio, with Silero's voice activity detection; transcribing only those parts
/// keeps Whisper from writing text over room noise (ivrit.ai's model then produces Knesset openings and "תודה רבה").
public actor SpeechDetector {
    private let manager: VadManager

    /// Loads the model, downloading it once if it isn't cached yet.
    public init() async throws {
        manager = try await VadManager()
    }

    /// Speech in 16 kHz mono samples, in seconds from their start, padded by `padding` on each side.
    ///
    /// At these settings it kept every word of the scripted read and 99.9% of a 32-minute meeting's, faint voices included,
    /// and in a quiet room it left out all but a few clicks and coughs of the room noise Whisper had written text over.
    /// - Parameter threshold: How sure the model must be that a moment is speech (0 to 1).
    public func speech(in samples: [Float], threshold: Float = 0.5, padding: Double = 0.3) async throws -> [ClosedRange<Double>] {
        let config = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.5, maxSpeechDuration: 30, speechPadding: padding, negativeThreshold: max(0, threshold - 0.15))
        return try await manager.segmentSpeech(samples, config: config).map { $0.startTime...$0.endTime }
    }
}
