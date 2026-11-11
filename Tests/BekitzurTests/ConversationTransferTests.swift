import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurLibrary

/// A Conversation exported as one file and imported on someone else's Mac.
struct ConversationTransferTests {
    private func temporary(_ extension: String? = nil) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bekitzur-transfer-\(UUID().uuidString)")
        return `extension`.map { url.appendingPathExtension($0) } ?? url
    }

    private func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// A reviewed Conversation with an audio track, and the .DS_Store Finder leaves in a folder it showed.
    private func conversation(in library: ConversationLibrary) throws -> ConversationInfo {
        var info = try library.create(language: .hebrew, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        info.status = .reviewed
        info.title = "Planning"
        try library.save(info)
        try Data("audio".utf8).write(to: library.folder(for: info.id).appending(path: "mic.m4a"))
        try Data("finder".utf8).write(to: library.folder(for: info.id).appending(path: ".DS_Store"))
        return info
    }

    @Test func anExportedConversationComesBackAsItWasAndPrivate() throws {
        let here = temporary(), there = temporary(), file = temporary(ConversationLibrary.fileExtension)
        defer { remove(here, there, file) }
        let library = ConversationLibrary(root: here), other = ConversationLibrary(root: there)
        let info = try conversation(in: library)

        try library.export(info.id, to: file)
        let imported = try other.importConversations(from: file)

        #expect(imported == [info])
        #expect(other.all() == [info])
        let folder = other.folder(for: info.id)
        #expect(try Data(contentsOf: folder.appending(path: "mic.m4a")) == Data("audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".DS_Store").path))
        #expect(other.audioTracks(for: info.id).map(\.lastPathComponent) == ["mic.m4a"])
        for file in ["info.json", "mic.m4a"] {
            #expect(try FileManager.default.attributesOfItem(atPath: folder.appending(path: file).path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
    }

    /// The chat is the user's own: it's kept with the Conversation, and left out when it's exported.
    @Test func theChatStaysWithItsUser() throws {
        let here = temporary(), there = temporary(), file = temporary(ConversationLibrary.fileExtension)
        defer { remove(here, there, file) }
        let library = ConversationLibrary(root: here), other = ConversationLibrary(root: there)
        let info = try conversation(in: library)
        var exchange = ChatExchange(message: "Who's doing the review?")
        exchange.answer = .notInConversation
        try library.save([exchange], for: info.id)

        try library.export(info.id, to: file)
        let imported = try other.importConversations(from: file)

        #expect(library.chat(for: info.id) == [exchange])
        #expect(imported.map(\.id) == [info.id])
        #expect(other.chat(for: info.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: other.folder(for: info.id).appending(path: ConversationLibrary.chatFile).path))
    }

    @Test func aConversationAlreadyHereComesInUnderAnIDOfItsOwn() throws {
        let root = temporary(), file = temporary(ConversationLibrary.fileExtension)
        defer { remove(root, file) }
        let library = ConversationLibrary(root: root)
        let info = try conversation(in: library)
        try library.export(info.id, to: file)

        let imported = try library.importConversations(from: file)

        #expect(imported.map(\.id) == [info.id + "-2"])
        #expect(library.all().count == 2)
        #expect(library.all().first { $0.id == info.id + "-2" }?.title == "Planning")
    }

    /// Conversations sent without exporting: a zip of the folder from Finder's Compress, or the folder unzipped.
    @Test func aZipFromFinderAndAFolderComeInToo() throws {
        let here = temporary(), there = temporary(), zip = temporary("zip")
        defer { remove(here, there, zip) }
        let library = ConversationLibrary(root: here), other = ConversationLibrary(root: there)
        let info = try conversation(in: library)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", library.folder(for: info.id).path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        #expect(try other.importConversations(from: zip).map(\.id) == [info.id])
        #expect(try other.importConversations(from: library.folder(for: info.id)).map(\.id) == [info.id + "-2"])
        #expect(library.all() == [info])
    }

    @Test func somethingElseIsntImported() throws {
        let root = temporary(), file = temporary(ConversationLibrary.fileExtension), folder = temporary()
        defer { remove(root, file, folder) }
        try Data("not a zip".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = ConversationLibrary(root: root)

        #expect(throws: ConversationLibrary.TransferError.self) { try library.importConversations(from: file) }
        #expect(throws: ConversationLibrary.TransferError.self) { try library.importConversations(from: folder) }
        #expect(library.all().isEmpty)
    }

    @Test func aSymbolicLinkIsRefused() throws {
        let here = temporary(), there = temporary()
        defer { remove(here, there) }
        let library = ConversationLibrary(root: here), other = ConversationLibrary(root: there)
        let info = try conversation(in: library)
        try FileManager.default.createSymbolicLink(at: library.folder(for: info.id).appending(path: "system.m4a"), withDestinationURL: URL(filePath: "/etc/hosts"))

        #expect(throws: ConversationLibrary.TransferError.self) { try other.importConversations(from: library.folder(for: info.id)) }
        #expect(other.all().isEmpty)
    }

    @Test func zipEntriesThatWouldLandOutsideAreCaught() {
        #expect(ConversationLibrary.escapes("../outside"))
        #expect(ConversationLibrary.escapes("2026-11-02-094909/../../outside"))
        #expect(ConversationLibrary.escapes("/etc/hosts"))
        #expect(!ConversationLibrary.escapes("2026-11-02-094909/info.json"))
        #expect(!ConversationLibrary.escapes("a..b/c"))
    }
}
