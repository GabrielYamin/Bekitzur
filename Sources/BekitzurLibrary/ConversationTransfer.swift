import BekitzurDomain
import Foundation

/// A Conversation as one file, to give to someone with Bekitzur: its folder, zipped, named with `fileExtension` so that
/// opening it imports it.
extension ConversationLibrary {
    public static let fileExtension = "bekitzur"

    public enum TransferError: Error, LocalizedError {
        case notAConversation
        case unsafe(String)
        case failed(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .notAConversation: "It isn't a Conversation exported from Bekitzur."
            case .unsafe(let name): "\(name) in it points outside the Conversation, so nothing was imported."
            case .failed(let tool, let status): "\(tool) stopped with error \(status)."
            }
        }
    }

    /// Writes a Conversation's folder, zipped, to `file`.
    public func export(_ id: String, to file: URL) throws {
        try? FileManager.default.removeItem(at: file)
        try Self.run("ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", folder(for: id).path, file.path])
    }

    /// Adds the Conversations in an exported file, a zip of Conversation folders, or a folder that is one or holds some,
    /// each under its own ID, or with "-2" and so on when a Conversation here has it. Their files are private, like the
    /// rest. Nothing is added if any of it would point outside its Conversation: an entry of the zip with ".." or starting
    /// with "/", which unzipping would write elsewhere, or a symbolic link.
    public func importConversations(from url: URL) throws -> [ConversationInfo] {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "bekitzur-import-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try fileManager.copyItem(at: url, to: staging.appending(path: url.lastPathComponent))
        } else {
            let entries = try Self.run("zipinfo", ["-1", url.path]).split(separator: "\n").map(String.init)
            if let entry = entries.first(where: Self.escapes) { throw TransferError.unsafe(entry) }
            try Self.run("ditto", ["-x", "-k", url.path, staging.path])
        }
        try Self.tidy(staging)
        let sources = Self.conversationFolders(in: staging)
        guard !sources.isEmpty else { throw TransferError.notAConversation }
        let infos = try sources.map { try Self.decoder.decode(ConversationInfo.self, from: Data(contentsOf: $0.appending(path: "info.json"))) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return try zip(sources, infos).map { source, info in
            var info = info
            info.id = freeID(from: Self.isFolderName(info.id) ? info.id : Self.id(for: info.startedAt))
            let destination = folder(for: info.id)
            try fileManager.moveItem(at: source, to: destination)
            try save(info)
            try Self.makePrivate(destination)
            return info
        }
    }

    /// Whether a zip entry's name would put it outside the folder it's unzipped into.
    static func escapes(_ entry: String) -> Bool {
        entry.hasPrefix("/") || entry.split(separator: "/").contains("..")
    }

    private static func isFolderName(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.contains("/") && !id.contains(":")
    }

    /// Takes out what Finder adds to folders and zips (.DS_Store, __MACOSX), which would count as audio tracks, and
    /// refuses symbolic links.
    private static func tidy(_ folder: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var extras: [URL] = []
        for case let item as URL in items {
            if item.lastPathComponent == "__MACOSX" || item.lastPathComponent == ".DS_Store" {
                extras.append(item)
            } else if try item.resourceValues(forKeys: Set(keys)).isSymbolicLink == true {
                throw TransferError.unsafe(item.lastPathComponent)
            }
        }
        for extra in extras { try? FileManager.default.removeItem(at: extra) }
    }

    /// The folder itself when it's a Conversation's, otherwise the Conversations' folders inside it.
    private static func conversationFolders(in folder: URL) -> [URL] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.appending(path: "info.json").path) { return [folder] }
        let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { fileManager.fileExists(atPath: $0.appending(path: "info.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func makePrivate(_ folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        guard let items = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let item as URL in items {
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try fileManager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: item.path)
        }
    }

    /// Runs one of macOS's own tools in /usr/bin and returns what it printed.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin").appending(path: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // zipinfo fails on anything that isn't a zip.
            throw tool == "zipinfo" ? TransferError.notAConversation : TransferError.failed(tool, process.terminationStatus)
        }
        return String(decoding: printed, as: UTF8.self)
    }
}
