import AppKit
import BekitzurCapture
import BekitzurDomain
import BekitzurPipeline
import SwiftUI
import UserNotifications

/// The app, or with `--live-transcription <he|en|auto>` its helper process, which transcribes live chunks so a crash in
/// whisper.cpp can't end a recording.
@main
enum Entry {
    static let liveTranscriptionArgument = "--live-transcription"

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: liveTranscriptionArgument) {
            // Never a second app, even for arguments from another version of it.
            let argument = arguments.dropFirst(index + 1).first ?? ""
            let language = ConversationLanguage(rawValue: argument)
            guard language != nil || argument == LiveTranscriptionHelper.detect else { exit(2) }
            exit(LiveTranscriptionHelper.serve(language: language))
        }
        if let index = arguments.firstIndex(of: AppRemoval.afterQuitArgument) {
            exit(AppRemoval.afterQuit(Array(arguments.dropFirst(index + 1))))
        }
        BekitzurApp.main()
    }
}

struct BekitzurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The app's bubble (drawn by scripts/make-icon.swift), with a dot while a Conversation waits for review.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let unreviewed = model.unreviewedCount > 0
        if let symbol = model.menuBarSymbol {
            Image(systemName: symbol)
        } else if let bubble = NSImage(named: unreviewed ? "MenuBarBadgedTemplate" : "MenuBarTemplate") {
            Image(nsImage: bubble)
        } else {
            Image(systemName: unreviewed ? "waveform.badge.exclamationmark" : "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var terminationSignal: DispatchSourceSignal?
    /// The build and install scripts quit the app with SIGTERM to replace it, which isn't removing it.
    private var quitBySignal = false
    /// The app that asked this one to quit, for the log.
    private var quitBy: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: AppModel.callNotification, actions: [UNNotificationAction(identifier: Self.record, title: "Record")], intentIdentifiers: []),
            UNNotificationCategory(identifier: AppModel.callEndedNotification, actions: [UNNotificationAction(identifier: Self.stop, title: "Stop and write Notes")], intentIdentifiers: []),
            UNNotificationCategory(identifier: AppModel.recordingCallNotification, actions: [UNNotificationAction(identifier: Self.stop, title: "Stop and write Notes")], intentIdentifiers: []),
        ])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let memory = Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded())
        AppLog.write("Launched build \(version); \(memory) GB of memory; microphone permission: \(MicrophoneRecorder.permission); system audio permission: \(SystemAudioRecorder.access.rawValue)")
        Task { AppLog.write("At launch, \(await AppModel.notificationSettings())") }

        // SIGTERM (pkill, the build script) would otherwise end the process before a recording's files are finished.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.quitBySignal = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source

        // The build script reopens the app after an update; only someone opening it by hand expects a window.
        if !CommandLine.arguments.contains("--background") {
            AppModel.shared.showMainWindow()
        }
    }

    /// Opening the app while it's running (Finder, Spotlight, Launchpad) shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showMainWindow()
        return false
    }

    /// Audio files and exported Conversations opened with Bekitzur in Finder, or dropped on its Dock icon, are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.showMainWindow()
        Task { await AppModel.shared.importRecordings(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEQuitApplication,
           let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value {
            quitBy = NSRunningApplication(processIdentifier: pid)?.localizedName
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopRecordingForQuit()
        if !quitBySignal, !AppModel.shared.isRemoving { AppRemoval.watchAfterQuitting() }
        AppLog.write(quitBy.map { "Quit, asked by \($0)" } ?? "Quit")
        AppLog.flush()
    }

    private static let record = "record"
    private static let stop = "stop"

    /// Clicking the offer to record a call records it, like its Record button; clicking the one to stop shows the
    /// recording, since only its button stops it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            switch id {
            case AppModel.updateNotification:
                model.showMainWindow()
            case AppModel.callNotification:
                Task { await model.startRecording() }
            case AppModel.callEndedNotification, AppModel.recordingCallNotification:
                if action == Self.stop { model.stopRecording() } else { model.showMainWindow(selecting: model.recordingID) }
            default:
                model.showMainWindow(selecting: id)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
