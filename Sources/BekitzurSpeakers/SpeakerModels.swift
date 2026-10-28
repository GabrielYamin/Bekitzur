import Foundation

/// FluidAudio's speaker and speech-detection models, which it downloads into its own cache the first time each loads.
public enum SpeakerModels {
    /// Loads each once, which downloads the ones that aren't cached yet.
    @concurrent
    public static func download() async throws {
        try await SpeakerSeparator().prepare()
        try await SortformerSeparator().prepare()
        _ = try await SpeechDetector()
    }
}
