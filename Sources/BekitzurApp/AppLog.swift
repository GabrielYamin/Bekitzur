import Foundation

/// A plain-text log in ~/Library/Logs/Bekitzur. Unlike the system log, it can be read without admin rights.
enum AppLog {
    static let url = URL.libraryDirectory.appending(path: "Logs/Bekitzur/Bekitzur.log")
    private static let queue = DispatchQueue(label: "bekitzur.log")
    /// Only read and written on `queue`.
    nonisolated(unsafe) private static var stopped = false

    static func write(_ message: String) {
        let line = "\(Date.ISO8601FormatStyle(timeZone: .current).format(Date())) \(message)\n"
        queue.async {
            guard !stopped else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? Data(line.utf8).write(to: url)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Waits for pending lines, for when the process is about to exit.
    static func flush() {
        queue.sync {}
    }

    /// Writes pending lines and nothing more, before the log goes to the Trash with the rest of Bekitzur's data.
    static func stop() {
        queue.sync { stopped = true }
    }
}
