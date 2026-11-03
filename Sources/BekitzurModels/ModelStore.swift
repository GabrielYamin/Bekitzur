import Foundation

/// The models folder: which model files are in it, and where the app reads each from.
public struct ModelStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func url(of file: ModelFile) -> URL {
        folder.appending(path: file.path)
    }

    /// Where a download collects before it's checked.
    public func partialURL(of file: ModelFile) -> URL {
        url(of: file).appendingPathExtension("partial")
    }

    /// The file is in: the pinned download, or any large file in its place, which is a copy this Mac already uses.
    public func has(_ file: ModelFile) -> Bool {
        guard let size = Self.size(of: url(of: file)) else { return false }
        return size == file.bytes || size > 100_000_000
    }

    /// Where the app reads a model: its own file, or until that's downloaded, the first file it replaces that's there.
    public func installed(_ file: ModelFile) -> URL? {
        if has(file) { return url(of: file) }
        return file.replaces.map { folder.appending(path: $0) }.first { Self.size(of: $0) != nil }
    }

    /// The models whose own file isn't in yet, even where a file they replace is.
    public func missing(_ files: [ModelFile] = ModelFile.all) -> [ModelFile] {
        files.filter { !has($0) }
    }

    /// Whether the app can read every one of these models.
    public func usable(_ files: [ModelFile] = ModelFile.all) -> Bool {
        files.allSatisfy { installed($0) != nil }
    }

    /// Bytes still to download for these models, less what their partial downloads hold.
    public func remainingBytes(_ files: [ModelFile]) -> Int64 {
        files.filter { !has($0) }.reduce(0) { total, file in
            total + max(0, file.bytes - (Self.size(of: partialURL(of: file)) ?? 0))
        }
    }

    /// Free space for downloads on the models folder's disk, as macOS counts it for things the user asked for.
    public func freeSpace() -> Int64? {
        var existing = folder
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Deletes the files a model replaces, once its own file is in, and the folders they leave empty.
    public func removeReplaced(by file: ModelFile) {
        guard has(file) else { return }
        for path in file.replaces {
            let old = folder.appending(path: path)
            try? FileManager.default.removeItem(at: old)
            let parent = old.deletingLastPathComponent()
            if parent != folder, (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    /// The size of a file, or of the file a symbolic link leads to; nil for anything else.
    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}
