import AppKit
import BekitzurPipeline
import BekitzurSpeakers

/// Removing Bekitzur. macOS moves only the app to the Trash, and lets it run on from there; its data, mostly the speech
/// models, stays where it is. So the app offers to move that to the Trash too, where it can be put back until the Trash
/// is emptied.
enum AppRemoval {
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
        alert.informativeText = [
            appInTrash ? "It's quitting." : "Bekitzur moves to the Trash and quits.",
            recording ? "The recording is stopped, and kept with your Conversations." : nil,
            "Its speech models take \(models), and your Conversations, voiceprints, and settings stay on this Mac for when you install Bekitzur again, unless you move them to the Trash too. You can put back what's in the Trash until you empty it.",
        ].compactMap { $0 }.joined(separator: " ")
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
        let items: [URL] = switch choice {
        case .appOnly: []
        case .models: modelFolders
        case .everything: [BekitzurPaths.appSupport] + SpeakerModels.folders + [caches, AppLog.url.deletingLastPathComponent(), httpStorage]
        }
        let fileManager = FileManager.default
        var failed: [URL] = []
        for item in items where fileManager.fileExists(atPath: item.path) {
            if (try? fileManager.trashItem(at: item, resultingItemURL: nil)) == nil { failed.append(item) }
        }
        // FluidAudio's folder goes too once no other app's models are in it.
        let others = (fileManager.subpaths(atPath: SpeakerModels.root.path) ?? []).filter { !["Models", ".DS_Store", "Models/.DS_Store"].contains($0) }
        if others.isEmpty { try? fileManager.trashItem(at: SpeakerModels.root, resultingItemURL: nil) }
        if choice == .everything, let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        return failed
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
        folders.reduce(0) { total, folder in
            let sizes = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])?
                .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize } } ?? []
            return total + Int64(sizes.reduce(0, +))
        }
    }
}
