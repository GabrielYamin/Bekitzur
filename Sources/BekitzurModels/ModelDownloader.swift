import CryptoKit
import Foundation

public enum ModelDownloadError: Error, Equatable, CustomStringConvertible {
    case unreachable(Int)
    case checksum(String)

    public var description: String {
        switch self {
        case .unreachable(let status): "Hugging Face answered with HTTP \(status)."
        case .checksum(let name): "The \(name.lowercased()) didn't match its checksum, so it was deleted."
        }
    }
}

/// How a model's download is going.
public enum DownloadProgress: Sendable, Equatable {
    /// The file's bytes so far, counting what an earlier download left.
    case received(Int64)
    /// Comparing the finished file with its checksum.
    case checking
}

/// Downloads a model file from its pinned URL into its partial file, continuing whatever is there, then checks the
/// SHA-256 and moves the file into place. A dropped connection or a server error is retried, from where it stopped,
/// five times. Cancelling the task stops the download and keeps what arrived.
public final class ModelDownloader: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let retryDelay: Duration
    private let log: @Sendable (String) -> Void

    /// - Parameter log: Told about each retry.
    public init(configuration: URLSessionConfiguration = .default, retryDelay: Duration = .seconds(5), log: @escaping @Sendable (String) -> Void = { _ in }) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration
        self.retryDelay = retryDelay
        self.log = log
    }

    public func download(_ file: ModelFile, into store: ModelStore, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let partial = store.partialURL(of: file)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        var retries = 0
        while true {
            var have = ModelStore.size(of: partial) ?? 0
            if have > file.bytes {
                try FileManager.default.removeItem(at: partial)
                have = 0
            }
            if have == file.bytes { break }
            do {
                try await Transfer(partial: partial, have: have, progress: progress).run(from: file.url, configuration: configuration)
                let size = ModelStore.size(of: partial) ?? 0
                if size == file.bytes { break }
                if size > file.bytes {
                    try? FileManager.default.removeItem(at: partial)
                    throw ModelDownloadError.checksum(file.name)
                }
                throw URLError(.networkConnectionLost)
            } catch let error where Self.isTransient(error) && retries < 5 {
                retries += 1
                log("\(file.name): \(error); trying again from byte \(ModelStore.size(of: partial) ?? 0)")
                try await Task.sleep(for: retryDelay)
            }
        }
        progress(.checking)
        guard try await Self.sha256(of: partial) == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.checksum(file.name)
        }
        let target = store.url(of: file)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is URLError: true
        case ModelDownloadError.unreachable(let status): status == 408 || status == 429 || status >= 500
        default: false
        }
    }

    /// Lowercase hex, read in 8 MB pieces off the caller's thread.
    @concurrent
    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try handle.read(upToCount: 8 << 20), !piece.isEmpty {
            try Task.checkCancellation()
            hash.update(data: piece)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One request for the rest of a file, appended to its partial download as it arrives.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    // Only used on the session's delegate queue.
    private var handle: FileHandle?
    private var received: Int64
    private var reported = Date.distantPast
    private var failure: Error?

    init(partial: URL, have: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.partial = partial
        self.received = have
        self.progress = progress
    }

    func run(from url: URL, configuration: URLSessionConfiguration) async throws {
        var request = URLRequest(url: url)
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let start: URLSessionDataTask? = lock.withLock {
                        guard !cancelled else { return nil }
                        self.continuation = continuation
                        task = session.dataTask(with: request)
                        return task
                    }
                    guard let start else { return continuation.resume(throwing: CancellationError()) }
                    start.resume()
                }
            } onCancel: {
                let task = lock.withLock {
                    cancelled = true
                    return self.task
                }
                task?.cancel()
            }
        } catch let error as URLError where error.code == .cancelled && lock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                self.handle = handle
            case 200:
                // The whole file, whatever was asked for; start over.
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                handle = try FileHandle(forWritingTo: partial)
                received = 0
            case 416:
                // The partial download is longer than the file on the server, so it isn't this file.
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                received = 0
                failure = URLError(.networkConnectionLost)
                return completionHandler(.cancel)
            default:
                failure = ModelDownloadError.unreachable(status)
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(reported) >= 0.25 {
                reported = Date()
                progress(.received(received))
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    /// Hugging Face sends each download on to its file servers; the rest of a file must still start where it stopped.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var request = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        progress(.received(received))
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
