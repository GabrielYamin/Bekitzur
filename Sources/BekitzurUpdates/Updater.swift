import CryptoKit
import Foundation
import Security

/// A release as its update.json describes it, signed by the release workflow.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public let version: String
    /// When the release was built, like 202610281119; newer releases have larger numbers.
    public let build: String
    public let url: URL
    /// Of the zip, in lowercase hex.
    public let sha256: String
    public let notes: String
    /// Ed25519, base64, over `signedMessage`.
    public let signature: String

    public init(version: String, build: String, url: URL, sha256: String, notes: String, signature: String) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.notes = notes
        self.signature = signature
    }

    /// What scripts/sign-update.swift signs; the two must stay the same. The URL and the notes aren't covered: a download
    /// has to match the signed checksum wherever it comes from.
    public var signedMessage: Data {
        Data("Bekitzur update\nversion \(version)\nbuild \(build)\nsha256 \(sha256)".utf8)
    }

    public func isSigned(by key: Curve25519.Signing.PublicKey) -> Bool {
        guard let signature = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(signature, for: signedMessage)
    }

    public func isNewer(than build: String) -> Bool {
        guard let release = UInt64(self.build), let running = UInt64(build) else { return false }
        return release > running
    }
}

public enum UpdateError: Error, CustomStringConvertible {
    case unreachable(Int)
    case unsigned
    case checksum
    case noApp
    case notBekitzur(OSStatus)
    case unzip(Int32)
    case notWritable(URL)

    public var description: String {
        switch self {
        case .unreachable(let status): "The releases page answered with HTTP \(status)."
        case .unsigned: "The release isn't signed with Bekitzur's release key, so it wasn't installed."
        case .checksum: "The download doesn't match the release, so it wasn't installed."
        case .noApp: "The download has no Bekitzur.app in it."
        case .notBekitzur(let status): "The app in the download isn't signed as Bekitzur (\(status)), so it wasn't installed."
        case .unzip(let status): "The download couldn't be unpacked (ditto exited with \(status))."
        case .notWritable(let folder): "Bekitzur can't replace itself in \(folder.path). Install the new version with install.sh instead."
        }
    }
}

/// Finds, checks, and installs new versions of Bekitzur from its releases page. Nothing is installed unless the release
/// is signed with the release key, the download matches the signed checksum, and the app in it is signed as Bekitzur.
public struct Updater: Sendable {
    public let feed: URL
    public let key: Curve25519.Signing.PublicKey
    /// This app's build, like 202610281119.
    public let build: String
    private let session: URLSession

    /// Nil unless the app says where its releases are and which key signs them (BekitzurUpdateFeed and
    /// BekitzurUpdatePublicKey in its Info.plist).
    public init?(feed: String?, publicKey: String?, build: String?) {
        guard let feed = feed.flatMap(URL.init(string:)), let build,
              let raw = publicKey.flatMap({ Data(base64Encoded: $0) }), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        self.feed = feed
        self.key = key
        self.build = build
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    /// The newest release, if it's newer than this build.
    public func check() async throws -> UpdateManifest? {
        let (data, response) = try await session.data(from: feed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.unreachable(status) }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard manifest.isSigned(by: key) else { throw UpdateError.unsigned }
        return manifest.isNewer(than: build) ? manifest : nil
    }

    /// Downloads a release and unpacks it into a temporary folder; returns its Bekitzur.app once it's checked.
    /// - Parameter progress: How much of the zip has arrived, from 0 to 1, on the session's queue.
    public func download(_ manifest: UpdateManifest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard manifest.isSigned(by: key) else { throw UpdateError.unsigned }
        let (downloaded, response) = try await session.download(from: manifest.url, delegate: DownloadProgress(report: progress))
        let folder = FileManager.default.temporaryDirectory.appending(path: "Bekitzur-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appending(path: "Bekitzur.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.unreachable(status) }
        guard try Self.sha256(of: zip) == manifest.sha256.lowercased() else { throw UpdateError.checksum }
        try Self.unzip(zip, into: folder)
        guard let app = Self.app(in: folder) else { throw UpdateError.noApp }
        try Self.checkSignature(of: app)
        return app
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unzip(_ zip: URL, into folder: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.unzip(ditto.terminationStatus) }
    }

    /// The release zip holds a Bekitzur folder with the app and install.sh.
    static func app(in folder: URL) -> URL? {
        [folder.appending(path: "Bekitzur/Bekitzur.app"), folder.appending(path: "Bekitzur.app")].first {
            FileManager.default.fileExists(atPath: $0.appending(path: "Contents/Info.plist").path)
        }
    }

    /// The app is intact and its signature names Bekitzur's identifier, as the build scripts sign it.
    static func checkSignature(of app: URL, identifier: String = "app.bekitzur.mac") throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.notBekitzur(status) }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
        guard status == errSecSuccess else { throw UpdateError.notBekitzur(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode)), requirement)
        guard status == errSecSuccess else { throw UpdateError.notBekitzur(status) }
    }

    /// Puts `newApp` where `current` is. The current app moves aside first, and back if the new one can't move in; what's
    /// left aside goes once the new app runs (`removeLeftovers`).
    public static func replace(_ current: URL, with newApp: URL) throws {
        let folder = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder) }
        let aside = folder.appending(path: "\(leftoverPrefix)\(UUID().uuidString).app")
        try FileManager.default.moveItem(at: current, to: aside)
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
        } catch {
            try? FileManager.default.moveItem(at: aside, to: current)
            throw error
        }
    }

    /// Removes what `replace` moved aside next to the app.
    public static func removeLeftovers(beside app: URL) {
        let folder = app.deletingLastPathComponent()
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(leftoverPrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static let leftoverPrefix = ".Bekitzur-replaced-"
}

/// Reports a download's progress as it arrives, from the task's own count of bytes.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in report(progress.fractionCompleted) }
    }
}
