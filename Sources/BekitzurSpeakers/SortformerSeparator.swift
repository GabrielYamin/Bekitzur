import FluidAudio
import Foundation

/// Separates voices with NVIDIA's Sortformer through FluidAudio: an end-to-end model for up to four voices that
/// doesn't cluster embeddings, so it follows quick exchanges. Its turns carry no embeddings.
public final class SortformerSeparator {
    public static let maximumVoices = 4

    private let diarizer = OfflineSortformerDiarizer()

    public init() {}

    /// Loads the model, downloading it on first use.
    public func prepare() async throws {
        try await diarizer.initializeFromHuggingFace()
    }

    public func separate(_ samples: [Float]) throws -> [SpeakerTurn] {
        try diarizer.processComplete(samples).speakers.values.flatMap { speaker in
            speaker.finalizedSegments.map {
                SpeakerTurn(voice: "S\($0.speakerIndex)", start: Double($0.startTime), end: Double($0.endTime), embedding: [])
            }
        }
    }
}
