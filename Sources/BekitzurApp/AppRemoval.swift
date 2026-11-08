import AppKit
import BekitzurPipeline
import BekitzurSpeakers
import BekitzurUpdates

/// Removing Bekitzur. macOS moves only the app to the Trash; its data, mostly the speech models, stays where it is. So
/// the app offers to move that to the Trash too, where it can be put back until the Trash is emptied. Finder quits a
/// running app before it moves it, so a helper the app starts as it quits watches for that (`watchAfterQuitting`).
enum AppRemoval {
    /// Runs the app as that helper: `--after-quit <pid> <app path>`.
    static let afterQuitArgument = "--after-quit"
    /// Read before the app's folder can move, which leaves its Info.plist behind.
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.bekitzur.mac"

    /// What goes to the Trash with the app.
    enum Choice {
        /// The speech models, which an install downloads again; Conversations, voiceprints, and settings stay for it.
        case models
        /// All Bekitzur keeps on this Mac, Conversations included.
        case everything
        case appOnly
    }

    /// Asks what of Bekitzur's data goes to the Trash with it. Deleting from Settings can be cancelled, which gives nil;
    /// once the app is in the Trash, it can't.
    @MainActor
    static func ask(appInTrash: Bool, recording: Bool) -> Choice? {
        let models = size(of: modelFolders).formatted(.byteCount(style: .file))
        let alert = NSAlert()
        alert.messageText = appInTrash ? "Bekitzur is in the Trash" : "Delete Bekitzur?"
        var text: [String] = []
        if !appInTrash { text.append("Bekitzur moves to the Trash and quits.") }
        if recording { text.append("The recording is stopped, and kept with your Conversations.") }
        text.append("Its speech models take \(models), and your Conversations, voiceprints, and settings stay on this Mac for when you install Bekitzur again, unless you move them to the Trash too. You can put back what's in the Trash until you empty it.")
        alert.informativeText = text.joined(separator: " ")
        alert.addButton(withTitle: appInTrash ? "Move the Models to the Trash" : "Delete with the Models")
        alert.addButton(withTitle: appInTrash ? "Move Everything to the Trash" : "Delete with Everything").hasDestructiveAction = true
        alert.addButton(withTitle: appInTrash ? "Keep Everything" : "Delete Only the App")
        if !appInTrash { alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}" }
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .models
        case .alertSecondButtonReturn: .everything
        case .alertThirdButtonReturn: .appOnly
        default: nil
        }
    }

    /// Moves what `choice` names to the Trash, the app itself aside; returns what couldn't be moved.
    static func moveToTrash(_ choice: Choice) -> [URL] {
        guard choice != .appOnly else { return [] }
        var items: [URL] = []
        if choice == .everything {
            items.append(BekitzurPaths.appSupport)
            items += SpeakerModels.folders
            items += [caches, AppLog.url.deletingLastPathComponent(), httpStorage]
        } else {
            items = modelFolders
        }
        let fileManager = FileManager.default
        var failed: [URL] = []
        for item in items where fileManager.fileExists(atPath: item.path) {
            if (try? fileManager.trashItem(at: item, resultingItemURL: nil)) == nil { failed.append(item) }
        }
        // FluidAudio's folder goes too once no other app's models are in it.
        let empty: Set<String> = ["Models", ".DS_Store", "Models/.DS_Store"]
        let others = (fileManager.subpaths(atPath: SpeakerModels.root.path) ?? []).filter { !empty.contains($0) }
        if others.isEmpty { try? fileManager.trashItem(at: SpeakerModels.root, resultingItemURL: nil) }
        if choice == .everything {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
        return failed
    }

    /// Moves what `choice` names to the Trash, and says what couldn't be moved. Moving everything, it stops the log
    /// first, which would otherwise come back.
    @MainActor
    static func moveToTrashSayingWhatFailed(_ choice: Choice) {
        guard choice != .appOnly else { return }
        AppLog.write(choice == .everything ? "Moving everything to the Trash" : "Moving the models to the Trash")
        if choice == .everything { AppLog.stop() }
        let failed = moveToTrash(choice)
        guard !failed.isEmpty else { return }
        let paths: [String] = failed.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let alert = NSAlert()
        alert.messageText = "Some of Bekitzur's data couldn't be moved to the Trash"
        alert.informativeText = "Move these to the Trash in Finder: \(paths.joined(separator: ", "))"
        NSApp.activate()
        alert.runModal()
    }

    /// Starts the helper that watches whether the app goes to the Trash once it has quit, and waits until it has the
    /// app's folder open, which must happen before Finder moves it.
    static func watchAfterQuitting() {
        guard let executable = Bundle.main.executableURL else { return }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [afterQuitArgument, String(getpid()), Bundle.main.bundleURL.path]
        let ready = Pipe()
        helper.standardOutput = ready
        helper.standardError = FileHandle.nullDevice
        helper.standardInput = FileHandle.nullDevice
        guard (try? helper.run()) != nil else { return }
        _ = ready.fileHandleForReading.readData(ofLength: 1)
    }

    /// The helper: if the app goes to the Trash within 15 seconds of quitting, asks what of its data goes too. Until
    /// then it's no app to macOS, so Finder doesn't wait for it.
    @MainActor
    static func afterQuit(_ arguments: [String]) -> Int32 {
        _ = bundleID
        guard arguments.count >= 2, let pid = pid_t(arguments[0]) else { return 2 }
        let descriptor = open(arguments[1], O_EVTONLY)
        FileHandle.standardOutput.write(Data("1".utf8))
        try? FileHandle.standardOutput.close()
        guard descriptor >= 0, TrashWatch.waitForTrash(descriptor: descriptor, after: pid, seconds: 15) else { return 0 }
        NSApplication.shared.setActivationPolicy(.accessory)
        AppLog.write("Moved to the Trash after quitting")
        moveToTrashSayingWhatFailed(ask(appInTrash: true, recording: false) ?? .appOnly)
        return 0
    }

    /// The speech models: Bekitzur's own, FluidAudio's it uses, and Core ML's compiled copies of them.
    static var modelFolders: [URL] {
        [BekitzurPaths.models] + SpeakerModels.folders + [caches]
    }

    private static var caches: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "app.bekitzur.mac")
    }

    private static var httpStorage: URL {
        URL.libraryDirectory.appending(path: "HTTPStorages/\(Bundle.main.bundleIdentifier ?? "app.bekitzur.mac")")
    }

    private static func size(of folders: [URL]) -> Int64 {
        var total: Int64 = 0
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
            for case let file as URL in files {
                total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }
}
