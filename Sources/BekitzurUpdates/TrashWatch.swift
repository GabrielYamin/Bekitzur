import Foundation

/// Tells when the app is moved to the Trash, which macOS doesn't: it watches the app's folder, which is renamed into the
/// Trash. An update moves it aside next to itself instead (`Updater.replace`). Finder quits a running app before it
/// moves it, so then it's a helper that watches, after the app quits (`waitForTrash`).
public final class TrashWatch {
    private let source: DispatchSourceFileSystemObject

    /// - Parameter movedToTrash: Called on the main queue once the app is in the Trash, or deleted outright.
    public init?(app: URL, movedToTrash: @escaping @MainActor () -> Void) {
        let descriptor = open(app.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.rename, .delete], queue: .main)
        source.setEventHandler { [weak source] in
            guard let source, source.data.contains(.delete) || Self.path(of: descriptor).map(Self.isInTrash) == true else { return }
            MainActor.assumeIsolated { movedToTrash() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }

    /// Once the process `pid` has quit, whether the folder open as `descriptor` goes to the Trash within `seconds`.
    public static func waitForTrash(descriptor: Int32, after pid: pid_t, seconds: Double) -> Bool {
        let quitBy = Date().addingTimeInterval(60)
        while kill(pid, 0) == 0, Date() < quitBy { usleep(100_000) }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let path = path(of: descriptor), isInTrash(path) { return true }
            usleep(200_000)
        }
        return false
    }

    /// Whether the item is in a Trash: the user's, or another volume's.
    public static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false),
           path.hasPrefix(trash.standardizedFileURL.path + "/") {
            return true
        }
        return url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Where the open folder is now.
    private static func path(of descriptor: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { URL(filePath: String(cString: $0.baseAddress!)) }
    }
}
