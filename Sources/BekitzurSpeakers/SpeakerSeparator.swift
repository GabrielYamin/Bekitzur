import FluidAudio
import Foundation

/// One stretch of speech by one voice, with that stretch's speaker embedding.
public struct SpeakerTurn: Sendable {
    /// The separator's own label for the voice, stable only within one Recording.
    public let voice: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]

    public var duration: Double { end - start }
}

/// Separates the voices in 16 kHz mono audio with FluidAudio's offline pipeline (pyannote community-1 on Core ML).
///
/// It folds quick replies into the surrounding speaker, and none of its settings for short speech changed that on the
/// two-person call, so ``SpeakerSeparation`` takes the timeline from Sortformer and only the embeddings from here.
public final class SpeakerSeparator {
    private let manager: OfflineDiarizerManager

    /// - Parameter people: How many people spoke, when the user knows; otherwise the pipeline decides.
    public init(people: Int? = nil) {
        manager = OfflineDiarizerManager(config: people.map { OfflineDiarizerConfig.default.withSpeakers(exactly: $0) } ?? .default)
    }

    /// Loads the models, downloading them on first use.
    public func prepare() async throws {
        try await manager.prepareModels()
    }

    public func separate(_ samples: [Float]) async throws -> [SpeakerTurn] {
        try await manager.process(audio: samples).segments.map {
            SpeakerTurn(
                voice: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds),
                embedding: $0.embedding
            )
        }
    }
}
