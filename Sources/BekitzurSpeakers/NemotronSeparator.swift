import FluidAudio
import Foundation

/// Separates voices with NVIDIA's Nemotron 3 Diarization through FluidAudio: Sortformer's successor, for up to eight
/// voices. Like Sortformer, it follows quick exchanges and its turns carry no embeddings.
public final class NemotronSeparator {
    public static let maximumVoices = 8

    /// FluidAudio's profile for complete recordings, which sees 30 seconds at a time.
    private let config = Nemotron3Config.offline
    private var diarizer: Nemotron3Diarizer?

    public init() {}

    /// Loads the model, downloading it on first use.
    public func prepare() async throws {
        diarizer = Nemotron3Diarizer(config: config, models: try await Nemotron3Models.loadFromHuggingFace(config: config))
    }

    public func separate(_ samples: [Float]) throws -> [SpeakerTurn] {
        guard let diarizer else { throw Nemotron3Error.invalidState("prepare() wasn't called") }
        let (probabilities, frames) = try diarizer.processComplete(samples)
        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames, numSpeakers: config.numSpeakers).map {
            SpeakerTurn(voice: "S\($0.speakerIndex)", start: Double($0.startSeconds), end: Double($0.endSeconds), embedding: [])
        }
    }
}
