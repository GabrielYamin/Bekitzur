import BekitzurUpdates
import Foundation
import Testing

/// Telling when the app is moved to the Trash, which macOS doesn't.
struct TrashWatchTests {
    @Test func theTrashIsTheUsersOrAnotherVolumes() {
        let home = URL.homeDirectory
        #expect(TrashWatch.isInTrash(home.appending(path: ".Trash/Bekitzur.app")))
        #expect(TrashWatch.isInTrash(URL(filePath: "/Volumes/Backup/.Trashes/501/Bekitzur.app")))
        #expect(!TrashWatch.isInTrash(home.appending(path: "Applications/Bekitzur.app")))
        // Where an update moves the app aside.
        #expect(!TrashWatch.isInTrash(home.appending(path: "Applications/.Bekitzur-replaced-1234.app")))
    }

    @MainActor
    @Test func anAppMovedElsewhereIsntNoticedButOneMovedToTheTrashIs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Bekitzur.app"), moved = root.appending(path: "Bekitzur 2.app"), trash = root.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let noticed = Count()
        let watch = try #require(TrashWatch(app: app) { noticed.value += 1 })

        try FileManager.default.moveItem(at: app, to: moved)
        try await Task.sleep(for: .milliseconds(200))
        #expect(noticed.value == 0)

        try FileManager.default.moveItem(at: moved, to: trash.appending(path: "Bekitzur.app"))
        for _ in 0..<50 where noticed.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(noticed.value == 1)
        withExtendedLifetime(watch) {}
    }
}

/// Finder quits a running app before it moves it to the Trash, so a helper watches after the app quits.
struct WaitForTrashTests {
    private func moved(into destination: String) async throws -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Bekitzur.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: destination), withIntermediateDirectories: true)
        let descriptor = open(app.path, O_EVTONLY)
        defer { close(descriptor) }
        let quitting = Process()
        quitting.executableURL = URL(filePath: "/bin/sleep")
        quitting.arguments = ["0.3"]
        try quitting.run()
        let pid = quitting.processIdentifier
        let seen = Task.detached { TrashWatch.waitForTrash(descriptor: descriptor, after: pid, seconds: 1.5) }
        quitting.waitUntilExit()
        try FileManager.default.moveItem(at: app, to: root.appending(path: "\(destination)/Bekitzur.app"))
        return await seen.value
    }

    @Test func anAppThatGoesToTheTrashAfterQuittingIsSeen() async throws {
        #expect(try await moved(into: ".Trash"))
    }

    @Test func anAppMovedElsewhereAfterQuittingIsnt() async throws {
        #expect(try await !moved(into: "Elsewhere"))
    }
}

@MainActor
private final class Count {
    var value = 0
}
