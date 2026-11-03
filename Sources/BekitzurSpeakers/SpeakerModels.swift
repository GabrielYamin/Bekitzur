import FluidAudio
import Foundation

/// FluidAudio's speaker and speech-detection models, which it downloads into its own cache the first time each loads.
public enum SpeakerModels {
    /// Loads each once, which downloads the ones that aren't cached yet.
    @concurrent
    public static func download() async throws {
        try await SpeakerSeparator().prepare()
        try await NemotronSeparator().prepare()
        _ = try await SpeechDetector()
    }

    /// Deletes Sortformer's files once Nemotron 3 Diarization's, which replace them, are downloaded: Sortformer is only
    /// the fallback until then.
    /// - Returns: The bytes freed, or nil when there was nothing to delete.
    @discardableResult
    public static func removeReplaced() -> Int64? {
        let fileManager = FileManager.default
        guard hasNemotron, fileManager.fileExists(atPath: sortformerFolder.path) else { return nil }
        let bytes = (fileManager.enumerator(at: sortformerFolder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize } }
            .reduce(0, +)) ?? 0
        guard (try? fileManager.removeItem(at: sortformerFolder)) != nil else { return nil }
        return Int64(bytes)
    }

    /// Whether Sortformer's files are on disk, to fall back on when Nemotron 3 Diarization can't load.
    static var hasSortformer: Bool {
        FileManager.default.fileExists(atPath: sortformerFolder.path)
    }

    /// Whether Nemotron 3 Diarization's model for whole recordings is downloaded: FluidAudio writes its weights marker
    /// only once a download is complete.
    static var hasNemotron: Bool {
        let folder = cache.appending(path: Repo.nemotron3Diarization.folderName)
        let config = Nemotron3Config.offline
        let model = folder.appending(path: "\(config.hubSubdirectory)/\(config.modelFileName)/coremldata.bin")
        let marker = folder.appending(path: ModelNames.Nemotron3.weightsVersionFile)
        return FileManager.default.fileExists(atPath: model.path) && FileManager.default.fileExists(atPath: marker.path)
    }

    private static var sortformerFolder: URL {
        cache.appending(path: Repo.sortformer.folderName)
    }

    /// FluidAudio's default cache.
    private static var cache: URL {
        URL.applicationSupportDirectory.appending(path: "FluidAudio/Models")
    }
}
