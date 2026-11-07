import BekitzurModels
import CryptoKit
import Foundation
import Synchronization
import Testing

struct ModelsTests {
    @Test func aModelOfSeveralFilesShowsOnceAndConversationsWaitOnlyForTheRequiredModels() {
        #expect(ModelFile.groups.map(\.name) == ["Hebrew speech model", "English speech model", "Language model", "Voice separation model"])
        #expect(ModelFile.groups.last?.files.count == 3)
        let separationBytes: Int64 = 617 + 1_693_600 + 116_277_056
        #expect(ModelFile.groups.last?.bytes == separationBytes)
        #expect(ModelFile.required == [.hebrewSpeech, .englishSpeech, .languageModel])
    }

    // MARK: Which models are in

    @Test func aModelIsInAsThePinnedFileOrALargeFileInItsPlace() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        let file = model("speech", bytes: 300_000_000)

        #expect(!store.has(file))
        try write(10, at: store.url(of: file))
        #expect(!store.has(file))
        try write(300_000_000, at: store.url(of: file))
        #expect(store.has(file))
        // A copy this Mac already uses, like a model whose metadata differs from the pinned download.
        try write(299_999_000, at: store.url(of: file))
        #expect(store.has(file))
        #expect(store.missing([file]).isEmpty)
    }

    @Test func untilItsDownloadedAModelIsReadFromTheFileItReplaces() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        let old = folder.appending(path: "old-speech/model.bin")
        let file = model("new-speech", bytes: 200_000_000, replaces: ["old-speech/model.bin"])
        try write(150_000_000, at: old)

        #expect(store.installed(file) == old)
        #expect(store.missing([file]) == [file])
        #expect(store.usable([file]))

        try write(200_000_000, at: store.url(of: file))
        store.removeReplaced(by: file)

        #expect(store.installed(file) == store.url(of: file))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
    }

    @Test func whatsLeftToDownloadLeavesOutPartialDownloads() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        let first = model("first", bytes: 5_000), second = model("second", bytes: 3_000)
        try write(1_000, at: store.partialURL(of: first))

        #expect(store.remainingBytes([first, second]) == 7_000)
        #expect(!store.usable([first, second]))
    }

    // MARK: Downloads

    @Test func aModelDownloadsAndMovesIntoPlaceOnceItsChecksumMatches() async throws {
        let (folder, file, data) = try serve("fresh")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        let reports = Reports()

        try await downloader().download(file, into: store) { reports.add($0) }

        #expect(try Data(contentsOf: store.url(of: file)) == data)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(of: file).path))
        #expect(reports.all.contains(.received(Int64(data.count))) && reports.all.last == .checking)
        #expect(StubServer.ranges(for: file) == [nil])
    }

    @Test func aDownloadContinuesWhereItStoppedThroughTheRedirect() async throws {
        let (folder, file, data) = try serve("resumed")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        try FileManager.default.createDirectory(at: store.partialURL(of: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(100_000).write(to: store.partialURL(of: file))

        try await downloader().download(file, into: store) { _ in }

        #expect(try Data(contentsOf: store.url(of: file)) == data)
        #expect(StubServer.ranges(for: file) == ["bytes=100000-"])
    }

    @Test func aServerThatIgnoresTheRangeStartsTheFileOver() async throws {
        let (folder, file, data) = try serve("whole", honorsRanges: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        try FileManager.default.createDirectory(at: store.partialURL(of: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(100_000).write(to: store.partialURL(of: file))

        try await downloader().download(file, into: store) { _ in }

        #expect(try Data(contentsOf: store.url(of: file)) == data)
    }

    @Test func aDownloadThatDoesntMatchItsChecksumIsDeleted() async throws {
        let (folder, served, _) = try serve("tampered")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder)
        let file = ModelFile(name: served.name, path: served.path, url: served.url, sha256: String(repeating: "0", count: 64), bytes: served.bytes)

        await #expect(throws: ModelDownloadError.checksum(file.name)) {
            try await downloader().download(file, into: store) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(of: file).path))
        #expect(!FileManager.default.fileExists(atPath: store.url(of: file).path))
    }

    @Test func aFileThatIsntThereIsntRetried() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = model("absent", bytes: 1_000)

        await #expect(throws: ModelDownloadError.unreachable(404)) {
            try await downloader().download(file, into: ModelStore(folder: folder)) { _ in }
        }
        #expect(StubServer.ranges(for: file).count == 1)
    }

    // MARK: Helpers

    private func downloader() -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return ModelDownloader(configuration: configuration, retryDelay: .milliseconds(10))
    }

    private func model(_ name: String, bytes: Int64, replaces: [String] = []) -> ModelFile {
        ModelFile(name: "Test model", path: "\(name)/model.bin", url: URL(string: "https://models.test/\(name)/model.bin")!,
                  sha256: "", bytes: bytes, replaces: replaces)
    }

    /// A model the stub server has, with a folder to download it into.
    private func serve(_ name: String, honorsRanges: Bool = true) throws -> (URL, ModelFile, Data) {
        let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: ($0 &* 7_919) % 251) })
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = ModelFile(name: "Test model", path: "\(name)/model.bin", url: URL(string: "https://models.test/\(name)/model.bin")!,
                             sha256: sha256, bytes: Int64(data.count))
        StubServer.serve(data, at: "/\(name)/model.bin", honorsRanges: honorsRanges)
        return (try temporaryFolder(), file, data)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bekitzur-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A file of that many bytes, without writing them.
    private func write(_ bytes: Int64, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }
}

/// What a download reported, from whichever thread reported it.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [DownloadProgress] = []

    func add(_ progress: DownloadProgress) {
        lock.withLock { reported.append(progress) }
    }

    var all: [DownloadProgress] {
        lock.withLock { reported }
    }
}

/// Serves files as Hugging Face does: models.test sends each request on to files.test, which sends the range asked
/// for, unless told to ignore ranges.
final class StubServer: URLProtocol, @unchecked Sendable {
    private struct Served {
        let data: Data
        let honorsRanges: Bool
    }

    private static let files = Mutex<[String: Served]>([:])
    private static let requests = Mutex<[String: [String?]]>([:])

    static func serve(_ data: Data, at path: String, honorsRanges: Bool) {
        files.withLock { $0[path] = Served(data: data, honorsRanges: honorsRanges) }
    }

    /// The Range header of each request that reached files.test for the file.
    static func ranges(for file: ModelFile) -> [String?] {
        requests.withLock { $0[file.url.path] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        if url.host == "models.test" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.host = "files.test"
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": components.url!.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: components.url!), redirectResponse: response)
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        Self.requests.withLock { $0[url.path, default: []].append(range) }
        guard let served = Self.files.withLock({ $0[url.path] }) else {
            return respond(404, headers: [:], body: Data())
        }
        if served.honorsRanges, let range, let start = Int(range.dropFirst("bytes=".count).dropLast()), start < served.data.count {
            let body = served.data.subdata(in: start..<served.data.count)
            respond(206, headers: ["Content-Range": "bytes \(start)-\(served.data.count - 1)/\(served.data.count)", "Content-Length": "\(body.count)"], body: body)
        } else {
            respond(200, headers: ["Content-Length": "\(served.data.count)"], body: served.data)
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network delivers it.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 64_000, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
