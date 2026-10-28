import ArgumentParser
import BekitzurModels
import BekitzurPipeline
import BekitzurSpeakers
import Foundation

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List the models Bekitzur reads, and download the missing ones as the app does."
    )

    @Flag(help: "Download the models that aren't there yet, then the speaker models.")
    var download = false

    @Option(help: "Models folder.")
    var folder: String = BekitzurPaths.models.path

    func run() async throws {
        let store = ModelStore(folder: URL(filePath: folder))
        for file in ModelFile.all {
            let state = store.has(file) ? "downloaded" : store.installed(file) != nil ? "not downloaded; reading the file it replaces" : "not downloaded"
            print("\(file.name), \(file.bytes.formatted(.byteCount(style: .file))): \(state)")
        }
        guard download else { return }
        let downloader = ModelDownloader(log: { log($0) })
        for file in store.missing() {
            let started = Date()
            let meter = Meter(total: file.bytes)
            log("Downloading the \(file.name.lowercased())")
            try await downloader.download(file, into: store) { progress in
                switch progress {
                case .received(let bytes): meter.show(bytes)
                case .checking: log("\nChecking it")
                }
            }
            store.removeReplaced(by: file)
            log(String(format: "Done in %.0f s", Date().timeIntervalSince(started)))
        }
        log("Loading the speaker models, which downloads them if they aren't cached yet")
        try await SpeakerModels.download()
    }
}

/// A download's percentage on one line of standard error, rewritten when it changes.
private final class Meter: @unchecked Sendable {
    private let total: Int64
    private let lock = NSLock()
    private var shown = -1

    init(total: Int64) {
        self.total = total
    }

    func show(_ bytes: Int64) {
        let percent = Int(100 * bytes / max(total, 1))
        let changed = lock.withLock {
            defer { shown = percent }
            return percent != shown
        }
        if changed { FileHandle.standardError.write(Data("\r\(percent)%".utf8)) }
    }
}
