import AppKit
import AVFoundation
import BekitzurCapture
import BekitzurDomain
import BekitzurLibrary
import BekitzurModels
import BekitzurPipeline
import BekitzurSpeakers
import BekitzurUpdates
import BekitzurVocabulary
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum VoiceSample: Equatable {
    case idle
    case recording(until: Date)
    case learning
    case learned(String)
    case failed(String)
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()
    static let voiceSampleSeconds = 30.0

    let library = ConversationLibrary(root: BekitzurPaths.conversations)
    private(set) var conversations: [ConversationInfo] = []
    private(set) var results: [String: ProcessedConversation] = [:] {
        didSet {
            for (id, result) in results where oldValue[id] != result { searchEntries[id] = SearchEntry(result, user: userName) }
        }
    }
    /// What each Conversation can be found by in the list's People menu and search, by ID: read from every Conversation
    /// at launch, then kept up to date as Notes are written and Speakers named.
    private(set) var searchEntries: [String: SearchEntry] = [:]
    /// The list's People menu and search.
    var filter = ConversationFilter()
    @ObservationIgnored private var indexing: Task<Void, Never>?
    /// What the user marked in each Transcript while listening back.
    private(set) var flags: [String: TranscriptFlags] = [:]
    /// The user's own English terms and the spellings their corrections taught.
    private(set) var vocabulary: Vocabulary
    private(set) var people: [String] = []
    @ObservationIgnored let vocabularyStore = VocabularyStore(url: BekitzurPaths.vocabulary)
    private(set) var recordingID: String?
    private(set) var recordingStartedAt: Date?
    /// A call app or browser that took the microphone while nothing was recording, offered in the menu bar and a
    /// notification until recording starts or the call is over.
    private(set) var callToRecord: String?
    /// The app of a call that ended during the recording, with an offer to stop, until recording stops or a call starts.
    private(set) var endedCall: String?
    var suggestsCalls: Bool {
        didSet {
            UserDefaults.standard.set(suggestsCalls, forKey: "suggestCalls")
            watchCalls()
        }
    }
    /// Recording starts when a call does, and stops once it's over, instead of being offered.
    var recordsCallsAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(recordsCallsAutomatically, forKey: "recordCallsAutomatically")
            watchCalls()
        }
    }
    /// The app of the call that started the recording, which stops it once the call is over; nil for a recording the
    /// user started, which a call ending only offers to stop.
    @ObservationIgnored private var recordingCall: String?
    /// Settings has something the user hasn't seen: a dot on the Settings buttons until they open it.
    private(set) var hasNewSettings: Bool
    /// Whether this Mac has the memory to write Notes (`RequirementsNote`).
    let memory = MemoryRequirement.thisMac
    /// The user read that this Mac has less memory than Bekitzur is made for.
    var memoryNoteSeen = UserDefaults.standard.bool(forKey: "memoryNoteSeen") {
        didSet { UserDefaults.standard.set(memoryNoteSeen, forKey: "memoryNoteSeen") }
    }
    /// The settings marked New while Settings is open: the ones that were new when it opened.
    private(set) var newSettingsShown: Set<NewSetting> = []
    @ObservationIgnored private var callWatch = CallWatch()
    @ObservationIgnored private var microphoneUsers: MicrophoneUsers?
    @ObservationIgnored private var callCheck: Task<Void, Never>?
    /// What's been transcribed of a Conversation while it was recorded, until its Notes are written.
    private(set) var liveTranscripts: [String: Transcript] = [:]
    /// Conversations whose live transcription stopped while they were recorded.
    private(set) var liveStopped: Set<String> = []
    /// Questions asked about each Conversation in this session, with what its Transcript says.
    private(set) var exchanges: [String: [Exchange]] = [:]
    /// The Conversation whose question is being answered; one question at a time.
    private(set) var askingID: String?
    @ObservationIgnored private let assistant = ConversationAssistant()

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: Answer?
        var failure: String?
    }
    private(set) var voiceSample: VoiceSample = .idle
    /// What macOS hasn't allowed Bekitzur yet.
    private(set) var missingPermissions: [MissingPermission] = []
    /// Models whose own file isn't downloaded yet, and the bytes left to download for them.
    private(set) var missingModels: [ModelFile] = []
    private(set) var modelBytesLeft: Int64 = 0
    /// The models' download while it runs, or why it stopped.
    private(set) var modelDownload: ModelDownload?
    @ObservationIgnored private var modelTask: Task<Void, Never>?

    struct ModelDownload {
        /// What's happening, like "Downloading the language model".
        var step: String
        /// Bytes downloaded so far, of what was left when it started.
        var received: Int64 = 0
        let total: Int64
        var failure: String?
    }
    /// A newer version, once a check found one.
    private(set) var availableUpdate: UpdateManifest?
    /// What the updater is doing, while it checks or downloads.
    private(set) var updateStep: String?
    /// How much of an update has downloaded, from 0 to 1, while it downloads.
    private(set) var updateProgress: Double?
    @ObservationIgnored private let updater = Updater(
        feed: Bundle.main.object(forInfoDictionaryKey: "BekitzurUpdateFeed") as? String,
        publicKey: Bundle.main.object(forInfoDictionaryKey: "BekitzurUpdatePublicKey") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
    @ObservationIgnored private var notifiedUpdate: String?
    var selection: String?
    var alert: String?
    /// The Conversation being renamed, while the Rename dialog shows.
    var renaming: String?
    /// Something that writes Notes the user changed again, waiting for them to agree.
    var replacingNotes: NotesReplacement?

    struct NotesReplacement {
        let id: String
        let write: @MainActor () -> Void
    }

    /// The language last detected, assumed for a Recording without speech to detect it from.
    @ObservationIgnored private var lastLanguage: ConversationLanguage {
        didSet { UserDefaults.standard.set(lastLanguage.rawValue, forKey: "language") }
    }

    var userName: String {
        didSet {
            UserDefaults.standard.set(userName, forKey: "userName")
            // The People menu leaves the user out, by this name; typed a letter at a time, so after a pause.
            indexConversations(after: .seconds(1))
        }
    }

    @ObservationIgnored private var recorder: ConversationRecorder?
    /// Keeps macOS from slowing Bekitzur down in the background, or sleeping, while it records.
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    @ObservationIgnored private var liveTranscriber: LiveTranscriber?
    @ObservationIgnored private var waiting: [String] = []
    /// Conversations whose next processing separates Speakers again but keeps the Transcript.
    @ObservationIgnored private var keepTranscript = Set<String>()
    /// Conversations whose next processing only writes the Notes again, from the Transcript with the user's fixes.
    @ObservationIgnored private var notesOnly = Set<String>()
    @ObservationIgnored private var processingID: String?
    @ObservationIgnored private lazy var mainWindow = WindowController(title: "Bekitzur", autosaveName: "Main", size: NSSize(width: 1040, height: 720)) {
        MainWindow(model: self)
    }
    @ObservationIgnored private lazy var settingsWindow = WindowController(title: "Bekitzur Settings", autosaveName: "Settings", size: NSSize(width: 560, height: 640)) {
        SettingsView(model: self)
    }

    private init() {
        lastLanguage = UserDefaults.standard.string(forKey: "language").flatMap(ConversationLanguage.init(rawValue:)) ?? .hebrew
        userName = UserDefaults.standard.string(forKey: "userName") ?? NSFullUserName()
        suggestsCalls = UserDefaults.standard.object(forKey: "suggestCalls") as? Bool ?? true
        recordsCallsAutomatically = UserDefaults.standard.bool(forKey: "recordCallsAutomatically")
        hasNewSettings = UserDefaults.standard.integer(forKey: "seenSettingsRevision") < NewSetting.revision
        vocabulary = VocabularyStore(url: BekitzurPaths.vocabulary).load()
        try? FileManager.default.createDirectory(at: BekitzurPaths.conversations, withIntermediateDirectories: true)
        conversations = library.all()
        reloadPeople()
        refreshModels()
        // The app quit while these were recording or processing; their audio is on disk, so process it now.
        for info in conversations.reversed() where info.status == .recording || info.status == .processing {
            enqueue(info.id)
        }
        // Coming back from System Settings makes the app active.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshPermissions()
                self?.refreshModels()
            }
        }
        Task { await refreshPermissions() }
        Task(priority: .utility) { await lineUpCalls() }
        Updater.removeLeftovers(beside: Bundle.main.bundleURL)
        if let freed = SpeakerModels.removeReplaced() {
            AppLog.write("Deleted Sortformer's model, which Nemotron 3 Diarization replaced: \(freed.formatted(.byteCount(style: .file)))")
        }
        Task { await checkForUpdatesRegularly() }
        watchCalls()
        indexConversations()
    }

    /// Reads every Conversation's Notes and Transcript for the list's People menu and search, off the main thread; a
    /// result already in memory is newer than its file while it's being saved, so it wins.
    func indexConversations(after delay: Duration = .zero) {
        indexing?.cancel()
        indexing = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let library = self.library, user = userName
            let ids = conversations.filter { $0.status == .unreviewed || $0.status == .reviewed }.map(\.id)
            let read = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: ids.compactMap { id in library.result(for: id).map { (id, SearchEntry($0, user: user)) } })
            }.value
            guard !Task.isCancelled else { return }
            searchEntries = read.merging(results.mapValues { SearchEntry($0, user: user) }) { _, loaded in loaded }
        }
    }

    // MARK: Updates

    var canUpdate: Bool { updater != nil }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// A minute after launch and every six hours; a new version waits for the user, who's told once.
    private func checkForUpdatesRegularly() async {
        guard updater != nil else { return }
        try? await Task.sleep(for: .seconds(60))
        while true {
            await checkForUpdates(manually: false)
            try? await Task.sleep(for: .seconds(6 * 3_600))
        }
    }

    func checkForUpdates(manually: Bool) async {
        guard let updater, updateStep == nil else { return }
        if manually { updateStep = "Checking for updates…" }
        defer { if manually { updateStep = nil } }
        do {
            guard let manifest = try await updater.check() else {
                availableUpdate = nil
                if manually { inform("Bekitzur is up to date", "This is the newest version, \(versionDescription).") }
                return
            }
            if availableUpdate != manifest { AppLog.write("Update \(manifest.version) (build \(manifest.build)) is available") }
            availableUpdate = manifest
            if manually {
                updateStep = nil
                installUpdate(manifest)
            } else {
                notifyUpdate(manifest)
            }
        } catch {
            AppLog.write("Update check failed: \(error)")
            if manually { inform("Couldn't check for updates", String(describing: error)) }
        }
    }

    /// Asks before installing, and first warns when a recording or processing would be cut short.
    func installUpdate(_ manifest: UpdateManifest) {
        guard let updater, updateStep == nil else { return }
        let notes = manifest.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (notes.isEmpty ? "" : "\(notes.prefix(800))\n\n") + "Bekitzur restarts to finish. Your Conversations and settings stay."
        guard ask("Install Bekitzur \(manifest.version)?", message, confirm: "Install", cancel: "Later"), allowInterruption() else { return }
        let wasBusy = isRecording || processingID != nil
        updateStep = "Downloading Bekitzur \(manifest.version)…"
        updateProgress = 0
        AppLog.write("Downloading update \(manifest.version)")
        Task {
            do {
                let app = try await updater.download(manifest) { fraction in
                    Task { @MainActor in
                        guard let current = AppModel.shared.updateProgress, fraction > current else { return }
                        AppModel.shared.updateProgress = fraction
                    }
                }
                updateProgress = nil
                updateStep = "Installing Bekitzur \(manifest.version)…"
                // A recording may have started during the download.
                if !wasBusy, isRecording || processingID != nil, !allowInterruption() {
                    updateStep = nil
                    return
                }
                try Updater.replace(Bundle.main.bundleURL, with: app)
                AppLog.write("Installed update \(manifest.version); restarting")
                relaunch()
            } catch {
                updateStep = nil
                updateProgress = nil
                AppLog.write("Update \(manifest.version) failed: \(error)")
                inform("Couldn't install Bekitzur \(manifest.version)", String(describing: error))
            }
        }
    }

    /// True when installing cuts nothing short, or the user agrees that it may.
    private func allowInterruption() -> Bool {
        if isRecording {
            return ask(
                "Bekitzur is recording",
                "Installing the update stops the recording and restarts Bekitzur. The recording is kept and processed after the restart.",
                confirm: "Stop Recording and Install", cancel: "Cancel"
            )
        }
        if processingID != nil {
            return ask(
                "Bekitzur is processing a Conversation",
                "Installing the update restarts Bekitzur, and the Conversation is processed again from the start after the restart.",
                confirm: "Install Now", cancel: "Cancel"
            )
        }
        return true
    }

    /// Opens the new app once this one has quit; quitting finishes a recording's files first.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    private func notifyUpdate(_ manifest: UpdateManifest) {
        guard notifiedUpdate != manifest.build else { return }
        notifiedUpdate = manifest.build
        Task {
            let content = UNMutableNotificationContent()
            content.title = "Bekitzur \(manifest.version) is available"
            content.body = "Open Bekitzur to install it."
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.updateNotification, content: content, trigger: nil))
        }
    }

    static let updateNotification = "update"

    private func ask(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    /// Lines up calls processed before they were measured, once, for playback: calls recorded before tracks were lined
    /// up while recording by how much later their microphone plays, then every call by how much later its system audio
    /// plays along the call. Waits while recording, so measuring never competes with it.
    private func lineUpCalls() async {
        for info in conversations where (info.microphoneDelay == nil || info.systemAudioDelays == nil) && info.status != .recording && info.status != .processing {
            while isRecording { try? await Task.sleep(for: .seconds(10)) }
            let tracks = library.audioTracks(for: info.id)
            let named = { (track: ConversationRecorder.Track) in tracks.first { $0.deletingPathExtension().lastPathComponent == track.name } }
            guard let microphone = named(.microphone), let system = named(.systemAudio) else { continue }
            var microphoneDelay = info.microphoneDelay
            if microphoneDelay == nil {
                let delay = await Self.measureMicrophoneDelay(microphone: microphone, system: system)
                guard conversations.first(where: { $0.id == info.id })?.microphoneDelay == nil else { continue }
                update(info.id) { $0.microphoneDelay = delay }
                microphoneDelay = delay
                AppLog.write(String(format: "%@: microphone track lined up, played %.0f ms later", info.id, delay * 1000))
            }
            let delays = await Self.measureSystemAudioDelays(microphone: microphone, system: system, microphoneDelay: microphoneDelay ?? 0)
            guard let current = conversations.first(where: { $0.id == info.id }), current.systemAudioDelays == nil,
                  current.status != .recording, current.status != .processing else { continue }
            update(info.id) { $0.systemAudioDelays = delays }
            AppLog.write("\(info.id): \(Self.describe(delays))")
        }
    }

    @concurrent
    private nonisolated static func measureMicrophoneDelay(microphone: URL, system: URL) async -> Double {
        ((try? ConversationProcessor.microphoneDelay(microphone: microphone, system: system)) ?? nil) ?? 0
    }

    @concurrent
    private nonisolated static func measureSystemAudioDelays(microphone: URL, system: URL, microphoneDelay: Double) async -> [TrackDelay] {
        (try? ConversationProcessor.systemAudioDelays(microphone: microphone, system: system, microphoneDelay: microphoneDelay)) ?? []
    }

    /// For the log: how a call's system audio was lined up.
    nonisolated static func describe(_ delays: [TrackDelay]) -> String {
        guard let first = delays.first, let last = delays.last else {
            return "system audio not lined up, since the microphone didn't hear the call"
        }
        let played = { (delay: Double) in String(format: "%.0f ms %@", abs(delay) * 1000, delay < 0 ? "earlier" : "later") }
        guard delays.count > 1 else { return "system audio lined up, played \(played(first.delay))" }
        return String(format: "system audio lined up, played %@ at first and %@ from %d:%02d, in %d steps",
                      played(first.delay), played(last.delay), Int(last.from) / 60, Int(last.from) % 60, delays.count - 1)
    }

    // MARK: Permissions

    func refreshPermissions() async {
        let missing = [
            MissingPermission(permission: .microphone, access: MicrophoneRecorder.access),
            MissingPermission(permission: .systemAudio, access: SystemAudioRecorder.access),
            MissingPermission(permission: .notifications, access: await Self.notificationAccess()),
        ].filter { $0.access == .denied || $0.access == .notAsked }
        guard missing != missingPermissions else { return }
        missingPermissions = missing
        AppLog.write(missing.isEmpty ? "Every permission granted" : "Not granted: " + missing.map { "\($0.permission.name) (\($0.access.rawValue))" }.joined(separator: ", "))
    }

    /// Asks for a permission the user hasn't been asked about, or opens its page in System Settings.
    func allow(_ missing: MissingPermission) {
        Task {
            if missing.access == .notAsked {
                switch missing.permission {
                case .microphone: _ = await MicrophoneRecorder.requestAccess()
                case .systemAudio: _ = await SystemAudioRecorder.requestAccess()
                case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
                await refreshPermissions()
                guard missingPermissions.contains(where: { $0.permission == missing.permission && $0.access == .notAsked }) else { return }
            }
            NSWorkspace.shared.open(missing.permission.settingsURL)
        }
    }

    private nonisolated static func notificationAccess() async -> Access {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }

    // MARK: Models

    func refreshModels() {
        let store = BekitzurPaths.modelStore
        let missing = store.missing()
        if missing != missingModels {
            AppLog.write(missing.isEmpty ? "Every model downloaded" : "Models to download: " + missing.map(\.name).joined(separator: ", "))
        }
        missingModels = missing
        modelBytesLeft = store.remainingBytes(missing)
    }

    /// What the models note says before a download starts.
    var modelsMessage: String {
        let size = modelBytesLeft.formatted(.byteCount(style: .file))
        if missingModels.allSatisfy({ BekitzurPaths.modelStore.installed($0) != nil }) {
            return missingModels.count == 1
                ? "A new \(missingModels[0].name.lowercased()) is ready to download (\(size))."
                : "New models are ready to download (\(size))."
        }
        return "Bekitzur needs its speech and language models to transcribe and write Notes: \(size) to download."
    }

    /// Downloads the missing models, then the speaker models, and processes the Conversations that waited for them.
    func downloadModels() {
        guard modelTask == nil else { return }
        if case .tooLow(let gigabytes) = memory {
            AppLog.write("Models not downloaded: this Mac has \(gigabytes) GB of memory")
            return
        }
        let store = BekitzurPaths.modelStore
        let files = store.missing()
        let total = store.remainingBytes(files)
        // The speaker models take another 250 MB or so.
        let needed = total + 500_000_000
        if let free = store.freeSpace(), free < needed {
            let failure = "Bekitzur needs \(needed.formatted(.byteCount(style: .file))) free for its models, and this Mac has \(free.formatted(.byteCount(style: .file)))."
            modelDownload = ModelDownload(step: "", total: total, failure: failure)
            AppLog.write("Models not downloaded: \(failure)")
            return
        }
        AppLog.write("Downloading the models: \(files.map(\.name).joined(separator: ", ")), \(total.formatted(.byteCount(style: .file))) to go")
        modelDownload = ModelDownload(step: "Starting the download", total: total)
        modelTask = Task { await runModelDownload(files, into: store) }
    }

    /// Stops the download; what arrived stays, and the next download continues from it.
    func stopModelDownload() {
        modelTask?.cancel()
    }

    private func runModelDownload(_ files: [ModelFile], into store: ModelStore) async {
        let downloader = ModelDownloader(log: { AppLog.write("Model download: \($0)") })
        var finished: Int64 = 0
        do {
            for file in files {
                let started = Date()
                let had = file.bytes - store.remainingBytes([file])
                let before = finished
                modelDownload?.step = "Downloading the \(file.name.lowercased())"
                try await downloader.download(file, into: store) { progress in
                    Task { @MainActor in AppModel.shared.modelDownloadProgressed(progress, file: file, had: had, before: before) }
                }
                finished += file.bytes - had
                store.removeReplaced(by: file)
                AppLog.write(String(format: "Downloaded the %@ in %.0f s", file.name.lowercased(), Date().timeIntervalSince(started)))
            }
            modelDownload?.step = "Downloading the speaker models"
            try await SpeakerModels.download()
            modelDownload = nil
            AppLog.write("Models ready")
        } catch is CancellationError {
            modelDownload = nil
            AppLog.write("Model download stopped; the next one continues from here")
        } catch {
            var reason = (error as? ModelDownloadError)?.description ?? error.localizedDescription
            if !reason.hasSuffix(".") { reason += "." }
            modelDownload?.failure = "The download stopped: \(reason) Trying again continues from where it stopped."
            AppLog.write("Model download failed: \(error)")
        }
        modelTask = nil
        refreshModels()
        processNext()
    }

    private func modelDownloadProgressed(_ progress: DownloadProgress, file: ModelFile, had: Int64, before: Int64) {
        guard modelTask != nil, modelDownload?.failure == nil else { return }
        switch progress {
        case .received(let bytes): modelDownload?.received = before + max(0, bytes - had)
        case .checking: modelDownload?.step = "Checking the \(file.name.lowercased())"
        }
    }

    // MARK: State for the menu bar

    var isRecording: Bool { recordingID != nil }

    var processing: ConversationInfo? {
        conversations.first { $0.status == .processing && $0.id == processingID }
    }

    var unreviewedCount: Int {
        conversations.filter { $0.status == .unreviewed }.count
    }

    /// What's happening, while recording or processing; otherwise nil, for the app's own bubble.
    var menuBarSymbol: String? {
        if isRecording { return endedCall == nil ? "record.circle.fill" : "stop.circle" }
        if callToRecord != nil { return "record.circle" }
        // Confirming the update closes the menu bar's panel, which had the only sign it was downloading.
        if updateProgress != nil { return "arrow.down.circle" }
        if processingID != nil { return "hourglass" }
        if let modelDownload, modelDownload.failure == nil { return "arrow.down.circle" }
        return nil
    }

    // MARK: Recording

    /// Live chunks are transcribed by a helper process, this app run with `Entry.liveTranscriptionArgument`, so a crash
    /// in whisper.cpp ends only live transcription; one took the whole app down mid-recording.
    static let transcribesLive = true

    /// Free space under which a recording starts only after a warning: a call takes under 100 MB an hour (77 to 78 MB
    /// for two calls, 31 for a room), so this is room for twenty hours.
    static let lowDiskSpace: Int64 = 2_000_000_000

    /// - Parameter automatically: For a call that started, where nobody's there to answer a question, so low disk space
    ///   is only told in a notification.
    func startRecording(automatically: Bool = false) async {
        guard recordingID == nil else { return }
        guard await MicrophoneRecorder.requestAccess() else {
            AppLog.write("Recording not started: microphone permission \(MicrophoneRecorder.permission)")
            alert = "Bekitzur needs the microphone. Allow it in System Settings → Privacy & Security → Microphone, then try again."
            await refreshPermissions()
            return
        }
        if let free = (try? BekitzurPaths.conversations.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < Self.lowDiskSpace {
            let space = free.formatted(.byteCount(style: .file))
            let why = "A recording takes under 100 MB an hour, but if the disk fills up, the rest of it is lost."
            AppLog.write("Starting a recording with \(space) free")
            if automatically {
                notify("low disk space", title: "Only \(space) free on this Mac", body: why)
            } else if !ask("Only \(space) free on this Mac", why, confirm: "Record Anyway", cancel: "Cancel") {
                return
            }
        }
        do {
            var info = try library.create()
            info.microphoneDelay = 0
            try library.save(info)
            let id = info.id
            var live: LiveTranscriber?
            let speechModels = BekitzurPaths.modelStore.usable([.hebrewSpeech, .englishSpeech])
            if Self.transcribesLive, speechModels, let app = Bundle.main.executableURL {
                let helper = HelperChunkTranscriber(executable: app, arguments: [Entry.liveTranscriptionArgument, LiveTranscriptionHelper.detect])
                live = LiveTranscriber(
                    language: lastLanguage,
                    chunks: helper,
                    tracks: ConversationRecorder.Track.allCases.count,
                    onUpdate: { transcript in Task { @MainActor in AppModel.shared.transcribedLive(transcript, for: id) } },
                    onFailure: { Task { @MainActor in AppModel.shared.liveFailed(id) } }
                )
            }
            var listener: ConversationRecorder.TrackListener?
            if let live {
                listener = { track, samples, sampleRate in live.receive(samples, sampleRate: sampleRate, track: track.rawValue) }
            }
            let recorder = ConversationRecorder()
            do {
                try recorder.start(in: library.folder(for: info.id), listener: listener)
            } catch {
                live?.cancel()
                try? library.delete(info.id)
                throw error
            }
            self.recorder = recorder
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a Conversation")
            liveTranscriber = live
            recordingID = info.id
            recordingStartedAt = info.startedAt
            conversations = library.all()
            selection = info.id
            AppLog.write("\(info.id): recording started")
            if !speechModels {
                liveStopped.insert(info.id)
                AppLog.write("\(info.id): no live Transcript, since the speech models aren't downloaded")
            }
            checkCall()
        } catch {
            AppLog.write("Recording not started: \(error)")
            alert = "Couldn't start recording: \(error)"
        }
    }

    func stopRecording() {
        guard let id = recordingID, let recorder else { return }
        let reports = recorder.stop()
        endRecordingActivity()
        AppLog.write("\(id): recording stopped after \(Int(Date().timeIntervalSince(recordingStartedAt ?? Date()))) s")
        log(reports, for: id)
        self.recorder = nil
        recordingID = nil
        recordingStartedAt = nil
        recordingCall = nil
        checkCall()
        let live = liveTranscriber
        liveTranscriber = nil
        update(id) {
            $0.endedAt = Date()
            $0.status = .processing
            $0.step = live == nil ? "Waiting" : "Finishing the live Transcript"
        }
        Task {
            if let live { await finishLive(live, for: id) }
            enqueue(id)
        }
    }

    private func endRecordingActivity() {
        if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
        recordingActivity = nil
    }

    /// How each track kept time: when its device started, and anything that went wrong on the way.
    private func log(_ reports: [ConversationRecorder.Track: TrackReport], for id: String) {
        AppLog.write(String(format: "%@: tracks lined up; system audio started after %.0f ms, the microphone after %.0f ms",
                            id, (reports[.systemAudio]?.leadingSilence ?? 0) * 1000, (reports[.microphone]?.leadingSilence ?? 0) * 1000))
        for track in ConversationRecorder.Track.allCases {
            guard let report = reports[track] else { continue }
            var problems: [String] = []
            if report.gaps > 0 {
                var gaps = String(format: "lost audio %d times on the way, %.0f ms in all, kept in time with silence", report.gaps, report.gapSeconds * 1000)
                if report.lostSeconds > 0 { gaps += String(format: " (%.0f ms while writing fell behind)", report.lostSeconds * 1000) }
                problems.append(gaps)
            }
            if report.overloads > 0 { problems.append("Core Audio was late \(report.overloads) times") }
            if report.restarts > 0 { problems.append("started over \(report.restarts) times after a change of device") }
            if report.failedWrites > 0 { problems.append("\(report.failedWrites) blocks couldn't be written") }
            guard !problems.isEmpty else { continue }
            AppLog.write("\(id): \(track == .microphone ? "the microphone" : "system audio") \(problems.joined(separator: "; "))")
        }
    }

    /// The helper process ended or a chunk couldn't be transcribed; the recording goes on, and its files are transcribed
    /// once it stops.
    private func liveFailed(_ id: String) {
        AppLog.write("\(id): live transcription stopped; the recording continues and will be transcribed from its files")
        liveStopped.insert(id)
    }

    /// Updates the live Transcript while recording; later updates are covered by `finishLive`. The first one has the
    /// language detected from the first speech.
    private func transcribedLive(_ transcript: Transcript, for id: String) {
        guard id == recordingID else { return }
        if liveTranscripts[id] == nil {
            AppLog.write("\(id): live Transcript started, in \(transcript.language.name)")
            update(id) { $0.language = transcript.language }
            lastLanguage = transcript.language
        }
        liveTranscripts[id] = transcript
        try? library.save(LiveTranscript(transcript: transcript, complete: false), for: id)
    }

    /// Transcribes what was recorded since the last chunk, so processing can start from the live Transcript.
    private func finishLive(_ live: LiveTranscriber, for id: String) async {
        let started = Date()
        guard let transcript = await live.finish() else {
            AppLog.write("\(id): live transcription failed; the recording will be transcribed from its files")
            return
        }
        liveTranscripts[id] = transcript
        try? library.save(LiveTranscript(transcript: transcript, complete: true), for: id)
        AppLog.write(String(format: "%@: live Transcript finished %.1f s after stopping, %d segments", id, Date().timeIntervalSince(started), transcript.segments.count))
    }

    // MARK: Call suggestions

    static let callNotification = "call"
    static let callEndedNotification = "call ended"
    static let recordingCallNotification = "recording call"

    private func watchCalls() {
        if suggestsCalls || recordsCallsAutomatically {
            if microphoneUsers == nil {
                microphoneUsers = MicrophoneUsers { [weak self] users in self?.microphoneUsersChanged(users) }
            }
            microphoneUsers?.start()
        } else {
            microphoneUsers?.stop()
            callCheck?.cancel()
            callWatch = CallWatch()
            offerRecording(nil)
            offerStopping(nil)
        }
    }

    private func microphoneUsersChanged(_ users: [String]) {
        AppLog.write(users.isEmpty ? "No other app is using the microphone" : "Using the microphone: \(users.joined(separator: ", "))")
        checkCall()
    }

    /// Offers to record a call, or to stop after one, when the apps using the microphone change, when recording starts or
    /// stops, and when an offer falls due.
    private func checkCall() {
        guard suggestsCalls || recordsCallsAutomatically, let microphoneUsers else { return }
        switch callWatch.update(using: microphoneUsers.bundleIDs, recording: isRecording, now: Date()) {
        case .record(let app):
            if recordsCallsAutomatically { recordCall(in: app) } else { offerRecording(app) }
        case .stop(let app):
            if recordingCall != nil { stopRecordingCall(in: app) } else if suggestsCalls { offerStopping(app) }
        case nil: break
        }
        if callToRecord != nil, isRecording || callWatch.call == nil { offerRecording(nil) }
        if endedCall != nil, !isRecording || callWatch.call != nil { offerStopping(nil) }
        callCheck?.cancel()
        guard let due = callWatch.nextCheck else { return }
        callCheck = Task {
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            checkCall()
        }
    }

    /// Records a call that started, as the user chose in Settings; it stops once the call is over.
    private func recordCall(in app: String) {
        guard !isRecording, voiceSample.isFinished else { return }
        Task {
            await startRecording(automatically: true)
            guard isRecording else { return }
            recordingCall = app
            AppLog.write("Started recording the call in \(app) on its own")
            notify(Self.recordingCallNotification, title: "Recording your call", body: "\(app) started using the microphone. Bekitzur stops recording when the call ends.")
        }
    }

    private func stopRecordingCall(in app: String) {
        guard let id = recordingID else { return }
        AppLog.write("Stopped recording on its own, since the call in \(app) ended")
        withdrawNotification(Self.recordingCallNotification)
        stopRecording()
        notify(id, title: "The call ended", body: "Bekitzur stopped recording the call in \(app) and is writing the Notes.")
    }

    private func offerRecording(_ app: String?) {
        callToRecord = app
        guard let app else { return withdrawNotification(Self.callNotification) }
        AppLog.write("Offered to record the call in \(app)")
        notify(Self.callNotification, title: "Record this call?", body: "\(app) started using the microphone.")
    }

    private func offerStopping(_ app: String?) {
        endedCall = app
        guard let app else { return withdrawNotification(Self.callEndedNotification) }
        AppLog.write("Offered to stop recording, since the call in \(app) ended")
        notify(Self.callEndedNotification, title: "Did the call end?", body: "\(app) stopped using the microphone. Stop recording and write Notes?")
    }

    /// Shows how Bekitzur's notifications look, and logs how macOS shows them, which the app can't see otherwise.
    func sendTestNotification() {
        notify("test", title: "Bekitzur's notifications work", body: "Offers to record a call will look like this.")
    }

    /// A notification with the actions of its category, registered at launch. What macOS does with it is logged, since
    /// one it doesn't show fails silently.
    private func notify(_ identifier: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = identifier
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                AppLog.write("Notification \"\(title)\" sent; \(await Self.notificationSettings())")
            } catch {
                AppLog.write("Notification \"\(title)\" not sent: \(error.localizedDescription); \(await Self.notificationSettings())")
            }
        }
    }

    /// How macOS shows Bekitzur's notifications, as System Settings → Notifications sets it.
    nonisolated static func notificationSettings() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorization = switch settings.authorizationStatus {
        case .authorized: "allowed"
        case .denied: "not allowed"
        case .notDetermined: "not asked yet"
        case .provisional: "allowed quietly"
        case .ephemeral: "allowed for now"
        @unknown default: "unknown"
        }
        let style = switch settings.alertStyle {
        case .none: "no banners"
        case .banner: "banners"
        case .alert: "alerts"
        @unknown default: "unknown style"
        }
        let center = settings.notificationCenterSetting == .enabled ? "in Notification Center" : "not in Notification Center"
        return "notifications \(authorization), \(style), \(center)"
    }

    private func withdrawNotification(_ identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Finishes the audio files so the Conversation is processed on the next launch.
    func stopRecordingForQuit() {
        guard let id = recordingID else { return }
        liveTranscriber?.cancel()
        liveTranscriber = nil
        let reports = recorder?.stop() ?? [:]
        endRecordingActivity()
        AppLog.write("\(id): recording stopped by quitting; it will be processed on the next launch")
        log(reports, for: id)
        update(id) {
            $0.endedAt = Date()
            $0.status = .processing
        }
    }

    // MARK: Processing

    /// Writes the Notes again from the same Transcript, so words marked in it stay marked.
    func writeNotesAgain(_ id: String) {
        keepTranscript.insert(id)
        reprocess(id)
    }

    /// Writes the Notes again from the Transcript with the user's fixes, without processing the audio again.
    func updateNotes(_ id: String) {
        notesOnly.insert(id)
        reprocess(id)
    }

    /// The user has fixed the Transcript since its Notes were written.
    func notesAreBehind(_ id: String) -> Bool {
        guard let result = results[id] else { return false }
        return (flags[id]?.fixes ?? []) != (result.notesFixes ?? [])
    }

    /// Transcribes the Recording again, in `language`, or detecting it when nil. Marks on the old Transcript's words are
    /// dropped, since its words are gone.
    func transcribeAgain(_ id: String, language: ConversationLanguage?) {
        library.deleteFlags(for: id)
        flags[id] = nil
        liveTranscripts[id] = nil
        update(id) { $0.language = language }
        reprocess(id)
    }

    private func reprocess(_ id: String) {
        update(id) {
            $0.status = .processing
            $0.step = "Waiting"
            $0.error = nil
        }
        enqueue(id)
    }

    /// Separates Speakers again, for as many people as the user says spoke (nil to let separation decide), then
    /// writes the Notes again. The Transcript is kept.
    func separateSpeakersAgain(_ id: String, people: Int?) {
        update(id) {
            $0.people = people
            $0.status = .processing
            $0.step = "Waiting"
            $0.error = nil
        }
        keepTranscript.insert(id)
        enqueue(id)
    }

    private func enqueue(_ id: String) {
        if !waiting.contains(id) { waiting.append(id) }
        processNext()
    }

    private func processNext() {
        guard processingID == nil, !waiting.isEmpty else { return }
        guard BekitzurPaths.modelStore.usable() else {
            for id in waiting { update(id) { $0.step = "Waiting for the models" } }
            return
        }
        let id = waiting.removeFirst()
        guard let info = conversations.first(where: { $0.id == id }) else { return processNext() }
        processingID = id
        update(id) {
            $0.status = .processing
            $0.step = "Starting"
            $0.error = nil
            $0.warning = nil
        }
        let folder = library.folder(for: id)
        let started = Date()
        let existing = results[id] ?? library.result(for: id)
        let notesOnly = self.notesOnly.remove(id) != nil ? existing : nil
        let kept = keepTranscript.remove(id) != nil ? existing?.transcript : nil
        let saved = library.liveTranscript(for: id).flatMap { info.language == nil || $0.transcript.language == info.language ? $0 : nil }
        // A live Transcript finished after the recording stopped saves transcribing the files; an unfinished one is only
        // used if the files can't be read.
        let live = kept == nil && notesOnly == nil && saved?.complete == true ? saved?.transcript : nil
        let salvage = notesOnly == nil ? saved?.transcript : nil
        let transcript = kept ?? live
        let flags = self.flags[id] ?? library.flags(for: id)
        let how = notesOnly != nil ? "Notes only" : kept != nil ? "same Transcript" : live != nil ? "live Transcript" : "new Transcript"
        AppLog.write("\(id): processing (\(info.language?.name ?? "language to detect")\(info.people.map { ", \($0) people" } ?? ""), \(how), \(flags.fixes.count) fixes)")
        Task {
            do {
                var result: ProcessedConversation
                let warning: String?
                let measuredDelay: Double?
                let measuredDelays: [TrackDelay]?
                if let notesOnly {
                    result = try await Self.rewrite(notesOnly, flags: flags, date: info.startedAt, language: notesOnly.transcript.language) { step in
                        Task { @MainActor in
                            AppModel.shared.update(id) { if $0.status == .processing { $0.step = step.rawValue } }
                        }
                    }
                    warning = info.warning
                    measuredDelay = nil
                    measuredDelays = nil
                } else {
                    (result, warning, measuredDelay, measuredDelays) = try await Self.run(
                        folder: folder,
                        date: info.startedAt,
                        language: info.language,
                        assumed: lastLanguage,
                        people: info.people,
                        microphoneDelay: info.microphoneDelay,
                        systemAudioDelays: info.systemAudioDelays,
                        transcript: transcript,
                        givenIsLive: kept == nil && live != nil,
                        salvage: salvage,
                        flags: flags
                    ) { step in
                        AppLog.write(String(format: "%@: %@ (%.0f s)", id, step.rawValue, Date().timeIntervalSince(started)))
                        Task { @MainActor in
                            AppModel.shared.update(id) { if $0.status == .processing { $0.step = step.rawValue } }
                        }
                    }
                }
                let current = conversations.first { $0.id == id }
                if current?.renamed == true, let title = current?.title { result.notes.title = title }
                try library.save(result, for: id)
                library.deleteLiveTranscript(for: id)
                liveTranscripts[id] = nil
                liveStopped.remove(id)
                results[id] = result
                let language = result.transcript.language
                update(id) {
                    $0.status = .unreviewed
                    $0.step = nil
                    if $0.renamed != true { $0.title = result.notes.title }
                    $0.warning = warning
                    $0.language = language
                    if let measuredDelay { $0.microphoneDelay = measuredDelay }
                    if let measuredDelays { $0.systemAudioDelays = measuredDelays }
                }
                if info.language == nil { lastLanguage = language }
                if let measuredDelay { AppLog.write(String(format: "%@: microphone track lined up, played %.0f ms later", id, measuredDelay * 1000)) }
                if let measuredDelays { AppLog.write("\(id): \(Self.describe(measuredDelays))") }
                let notes = result.notes
                AppLog.write(String(
                    format: "%@: Notes ready after %.0f s: %@, %d Speakers, %d Decisions, %d Action Items, %d Open Questions",
                    id, Date().timeIntervalSince(started), language.name, result.speakers.count, notes.decisions.count, notes.actionItems.count, notes.openQuestions.count
                ))
                if let warning { AppLog.write("\(id): warning: \(warning)") }
                notifyNotesReady(id: id, title: result.notes.title)
            } catch {
                AppLog.write("\(id): failed after \(Int(Date().timeIntervalSince(started))) s: \(error)")
                update(id) {
                    $0.status = .failed
                    $0.step = nil
                    $0.error = String(describing: error)
                }
            }
            processingID = nil
            processNext()
        }
    }

    @concurrent
    private nonisolated static func rewrite(
        _ result: ProcessedConversation,
        flags: TranscriptFlags,
        date: Date,
        language: ConversationLanguage,
        progress: @escaping @Sendable (ProcessingStep) -> Void
    ) async throws -> ProcessedConversation {
        try ConversationProcessor.rewriteNotes(
            result,
            flags: flags,
            vocabulary: VocabularyStore(url: BekitzurPaths.vocabulary).load(),
            date: date,
            language: language,
            progress: progress
        )
    }

    /// Processes every audio file in the Conversation's folder: the two recorded tracks, or an imported recording.
    /// - Parameters:
    ///   - language: Nil to detect it.
    ///   - assumed: The language for a Recording without speech to detect it from.
    ///   - microphoneDelay: How much later to play the microphone track; measured here when nil, and returned.
    ///   - systemAudioDelays: How much later to play the system audio track along a call; measured here when nil, and
    ///     returned.
    ///   - transcript: A Transcript already made, used if it's in `language`.
    ///   - givenIsLive: `transcript` is the live Transcript, from both tracks summed, which a call doesn't use.
    ///   - salvage: A live Transcript to write the Notes from if the audio can't be read, as when the app quit before it
    ///     finished the files.
    @concurrent
    private nonisolated static func run(
        folder: URL,
        date: Date,
        language: ConversationLanguage?,
        assumed: ConversationLanguage,
        people: Int?,
        microphoneDelay: Double?,
        systemAudioDelays: [TrackDelay]?,
        transcript given: Transcript?,
        givenIsLive: Bool,
        salvage: Transcript?,
        flags: TranscriptFlags,
        progress: @escaping @Sendable (ProcessingStep) -> Void
    ) async throws -> (result: ProcessedConversation, warning: String?, measuredDelay: Double?, measuredDelays: [TrackDelay]?) {
        for track in RecordingFiles.unfinished(in: folder) {
            do {
                try RecordingFiles.finish(track)
            } catch {
                AppLog.write("\(folder.lastPathComponent): \(track.lastPathComponent) stays as recorded: \(error)")
            }
        }
        let tracks = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let audio: MixedAudio
        do {
            audio = try ConversationProcessor.loadMixed(tracks)
        } catch {
            guard let salvage, !salvage.segments.isEmpty else { throw error }
            let result = try ConversationProcessor.rewriteNotes(
                ProcessedConversation(transcript: salvage, speakers: [], turns: [], notes: Notes()),
                flags: flags,
                vocabulary: VocabularyStore(url: BekitzurPaths.vocabulary).load(),
                date: date,
                language: salvage.language,
                progress: progress
            )
            let minutes = Int(((salvage.segments.last?.end ?? 0) / 60).rounded(.up))
            return (result, "The audio couldn't be read because the app quit before finishing it, so these Notes come from the live Transcript of the first \(minutes) minutes, without Speakers.", nil, nil)
        }
        let byName = Dictionary(audio.tracks.map { ($0.key.deletingPathExtension().lastPathComponent, $0.value) }, uniquingKeysWith: { first, _ in first })
        var call = byName[ConversationRecorder.Track.microphone.name].flatMap { microphone in
            byName[ConversationRecorder.Track.systemAudio.name].map { CallTracks(microphone: microphone, system: $0) }
        }
        var samples = audio.samples
        var measuredDelay: Double?
        if let tracks = call {
            let delay: Double
            if let microphoneDelay {
                delay = microphoneDelay
            } else {
                delay = tracks.measuredMicrophoneDelay ?? 0
                measuredDelay = delay
            }
            if delay > 0 {
                let lined = tracks.delayingMicrophone(by: delay)
                call = lined.tracks
                samples = lined.mixed
            }
        }
        var measuredDelays: [TrackDelay]?
        if let tracks = call {
            let delays = systemAudioDelays ?? tracks.measuredSystemAudioDelays
            if systemAudioDelays == nil { measuredDelays = delays }
            if !delays.isEmpty {
                let lined = tracks.placingSystemAudio(by: delays)
                call = lined.tracks
                samples = lined.mixed
            }
        }
        var microphoneSpeech: [ClosedRange<Double>] = []
        if let tracks = call {
            let cleaned = tracks.removingEcho()
            call = cleaned.tracks
            samples = cleaned.mixed
            microphoneSpeech = cleaned.microphoneSpeech
        }
        // A call's tracks are transcribed each on its own, so two people talking at once both make it into the
        // Transcript; the live Transcript, from both tracks summed, doesn't do for a call.
        var eachTrack: CallTracks?
        if let tracks = call, try await SpeakerSeparation.isCall(system: tracks.system) { eachTrack = tracks }
        let transcript: Transcript
        if let given, language == nil || given.language == language, !(givenIsLive && eachTrack != nil) {
            transcript = given
        } else if let tracks = eachTrack {
            progress(.transcribing)
            let system = try await transcribeInHelper(tracks.system, language: language ?? given?.language, assumed: assumed)
            let microphone = try await transcribeInHelper(tracks.microphone, language: system.language, assumed: assumed)
            transcript = ConversationProcessor.merging(microphone: microphone, system: system, microphoneSpeech: microphoneSpeech)
        } else {
            progress(.transcribing)
            transcript = try await transcribeInHelper(samples, language: language, assumed: assumed)
        }
        let voiceprints = (try? VoiceprintStore(url: BekitzurPaths.voiceprints).load()) ?? []
        let result = try await ConversationProcessor.process(
            samples,
            date: date,
            language: transcript.language,
            voiceprints: voiceprints,
            people: people,
            call: call,
            transcript: transcript,
            flags: flags,
            vocabulary: VocabularyStore(url: BekitzurPaths.vocabulary).load(),
            progress: progress
        )
        let silent = Set(audio.silentTracks.map { $0.deletingPathExtension().lastPathComponent })
        var warning: String?
        // With the permission, silent system audio means nothing played, as in a room.
        if silent.contains(ConversationRecorder.Track.systemAudio.name), SystemAudioRecorder.access != .granted {
            warning = "No computer audio was recorded, so these Notes only have what your microphone heard. If this was a call, allow Bekitzur in System Settings → Privacy & Security → Screen & System Audio Recording."
        } else if silent.contains(ConversationRecorder.Track.microphone.name) {
            warning = "Your microphone recorded only silence. Check the input device in System Settings → Sound."
        }
        return (result, warning, measuredDelay, measuredDelays)
    }

    /// Transcribes a whole Recording as live transcription does, in the helper process: a crash in whisper.cpp then fails
    /// this Conversation instead of the app, and the app's every launch after it, since unfinished Conversations resume.
    /// - Parameters:
    ///   - language: Nil to detect it.
    ///   - assumed: The language for a Recording without speech to detect it from.
    private nonisolated static func transcribeInHelper(_ samples: [Float], language: ConversationLanguage?, assumed: ConversationLanguage) async throws -> Transcript {
        guard let app = Bundle.main.executableURL else { throw ProcessingError.transcriptionStopped }
        let helper = HelperChunkTranscriber(
            executable: app,
            arguments: [Entry.liveTranscriptionArgument, language?.rawValue ?? LiveTranscriptionHelper.detect]
        )
        let live = LiveTranscriber(language: language ?? assumed, chunks: helper, tracks: 1) { _ in }
        samples.withUnsafeBufferPointer { buffer in
            let minute = 60 * 16_000
            for start in stride(from: 0, to: buffer.count, by: minute) {
                live.receive(UnsafeBufferPointer(rebasing: buffer[start..<min(start + minute, buffer.count)]), sampleRate: 16_000, track: 0)
            }
        }
        guard let transcript = await live.finish() else { throw ProcessingError.transcriptionStopped }
        return transcript
    }

    // MARK: Importing

    /// A Conversation exported from Bekitzur (`ConversationLibrary.export`).
    static let conversationType = UTType(filenameExtension: ConversationLibrary.fileExtension, conformingTo: .zip) ?? .zip

    /// Asks for recordings to import, with how many people spoke in them, or Conversations exported from Bekitzur.
    func chooseRecordingsToImport() async {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose recordings, or Conversations exported from Bekitzur."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio, Self.conversationType, .zip, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let people = NSPopUpButton()
        people.addItems(withTitles: Self.peopleChoices.map(Self.peopleTitle))
        let accessory = NSStackView(views: [NSTextField(labelWithString: "People who spoke:"), people])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        NSApp.activate()
        guard await panel.begin() == .OK else { return }
        await importRecordings(panel.urls, people: Self.peopleChoices[people.indexOfSelectedItem])
    }

    /// "Let Bekitzur decide", then 2 to 8 people.
    static let peopleChoices: [Int?] = [nil] + Array(2...8)

    static func peopleTitle(_ people: Int?) -> String {
        people.map { "\($0) people" } ?? "Let Bekitzur decide"
    }

    /// Copies recordings into new Conversations and processes them, and adds Conversations exported from Bekitzur as
    /// they are. A Conversation is dated from the recording's metadata when it has a date, since due dates like
    /// "tomorrow" are counted from it, and from the file otherwise.
    func importRecordings(_ urls: [URL], people: Int? = nil) async {
        let exported = urls.filter(Self.isExportedConversation)
        for url in exported { await importConversations(from: url) }
        for url in urls where !exported.contains(url) {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let recorded = try? await asset.load(.creationDate)?.load(.dateValue)
                let fileDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                let startedAt = recorded ?? fileDate ?? Date()
                var info = try library.create(startedAt: startedAt)
                let copy = library.folder(for: info.id).appending(path: "recording.\(url.pathExtension.lowercased())")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                } catch {
                    try? library.delete(info.id)
                    throw error
                }
                info.endedAt = startedAt.addingTimeInterval(duration.isFinite ? duration : 0)
                info.people = people
                info.status = .processing
                info.step = "Waiting"
                info.title = url.deletingPathExtension().lastPathComponent
                try library.save(info)
                conversations = library.all()
                selection = info.id
                AppLog.write("\(info.id): imported \(url.lastPathComponent) (\(Int(duration)) s, dated \(recorded == nil ? "from the file" : "from its metadata"))")
                enqueue(info.id)
            } catch {
                AppLog.write("Import of \(url.lastPathComponent) failed: \(error)")
                alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A Conversation's file, a zip, as Conversations were sent before there was one, or a folder.
    private static func isExportedConversation(_ url: URL) -> Bool {
        ["bekitzur", "zip"].contains(url.pathExtension.lowercased()) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Adds the Conversations in an exported file or folder as they are, and processes one that was recording or
    /// processing when it was exported.
    private func importConversations(from url: URL) async {
        let library = self.library
        do {
            let imported = try await Task.detached { try library.importConversations(from: url) }.value
            conversations = library.all()
            for info in imported {
                AppLog.write("\(info.id): imported from \(url.lastPathComponent)")
                if info.status == .recording || info.status == .processing {
                    update(info.id) {
                        $0.status = .processing
                        $0.step = "Waiting"
                    }
                    enqueue(info.id)
                }
            }
            if let last = imported.last { selection = last.id }
            indexConversations()
        } catch {
            AppLog.write("Import of \(url.lastPathComponent) failed: \(error)")
            alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Asks where to save a Conversation as one file, to give to someone with Bekitzur, who opens it to import it.
    func export(_ id: String) async {
        guard let info = conversations.first(where: { $0.id == id }), info.status != .recording, info.status != .processing else { return }
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.message = "Someone with Bekitzur can open this file to add the Conversation, with its recording, Transcript, Speakers, and Notes."
        panel.prompt = "Export"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "\(Self.fileName(info.displayTitle)) \(day.string(from: info.startedAt)).\(ConversationLibrary.fileExtension)"
        panel.allowedContentTypes = [Self.conversationType]
        NSApp.activate()
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let library = self.library
        do {
            try await Task.detached { try library.export(id, to: url) }.value
            AppLog.write("\(id): exported")
        } catch {
            AppLog.write("\(id): export failed: \(error)")
            alert = "Couldn't export the Conversation: \(error.localizedDescription)"
        }
    }

    /// Opens an Action Item with a due day as an event in whichever app opens calendar files, where the user adds it.
    func addToCalendar(_ item: ActionItem, in id: String) {
        guard let info = conversations.first(where: { $0.id == id }),
              let event = CalendarEvent(item, conversationID: id, conversationTitle: info.displayTitle, conversationDate: info.startedAt) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Bekitzur calendar events", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appending(path: "\(Self.fileName(item.text)).ics")
            try Data(event.ics().utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard NSWorkspace.shared.open(file) else {
                alert = "No app on this Mac opens calendar files."
                return
            }
            AppLog.write("\(id): an Action Item went to the calendar app")
        } catch {
            alert = "Couldn't make the calendar event: \(error.localizedDescription)"
        }
    }

    /// A title as a file name: without the slashes and colons Finder can't show, and not too long.
    private static func fileName(_ title: String) -> String {
        String(title.map { "/:".contains($0) ? "-" : $0 }.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func notifyNotesReady(id: String, title: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            await refreshPermissions()
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "Notes ready"
            content.body = title
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: Review

    func loadResult(_ id: String) {
        if results[id] == nil { results[id] = library.result(for: id) }
    }

    func markReviewed(_ id: String) {
        update(id) { $0.status = .reviewed }
    }

    func markUnreviewed(_ id: String) {
        update(id) { $0.status = .unreviewed }
    }

    /// Names a Speaker in one Conversation and remembers their voice for the next ones.
    func nameSpeaker(_ label: String, as name: String, in id: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let result = results[id] ?? library.result(for: id),
              let speaker = result.speakers.first(where: { $0.label == label }) else { return }
        let renamed = result.renamingSpeaker(label, to: name)
        let old = speaker.displayName
        do {
            try library.save(renamed, for: id)
            results[id] = renamed
            changeFlags(id) { flags in
                for i in flags.words.indices where flags.words[i].saidBy == old { flags.words[i].saidBy = name }
            }
            try VoiceprintStore(url: BekitzurPaths.voiceprints).add(speaker.embedding, to: name)
            reloadPeople()
        } catch {
            alert = "Couldn't save the name: \(error)"
        }
    }

    /// The user said a suggested name is wrong.
    func rejectSuggestion(_ label: String, in id: String) {
        guard var result = results[id], let index = result.speakers.firstIndex(where: { $0.label == label }) else { return }
        result.speakers[index].naming = .unknown
        try? library.save(result, for: id)
        results[id] = result
    }

    /// Saves the user's changes to a Conversation's Notes; a new title renames the Conversation too.
    func saveNotes(_ notes: Notes, for id: String) {
        guard var result = results[id] ?? library.result(for: id) else { return }
        let renamed = notes.title != result.notes.title
        result.notes = notes
        result.notesEdited = true
        do {
            try library.save(result, for: id)
            results[id] = result
        } catch {
            alert = "Couldn't save the Notes: \(error.localizedDescription)"
            return
        }
        if renamed {
            update(id) {
                $0.title = notes.title
                $0.renamed = true
            }
        }
    }

    /// Checks an Action Item off, or back on.
    func setActionItem(_ index: Int, done: Bool, in id: String) {
        guard var result = results[id] ?? library.result(for: id), result.notes.actionItems.indices.contains(index) else { return }
        result.notes.actionItems[index].done = done ? true : nil
        do {
            try library.save(result, for: id)
            results[id] = result
        } catch {
            alert = "Couldn't save the Action Item: \(error.localizedDescription)"
        }
    }

    /// How long Not now puts off asking again to delete a Conversation whose Action Items are all done.
    static let deletingAskedAgain: TimeInterval = 7 * 24 * 3_600

    /// Every Action Item in the Conversation is done, and the user hasn't put off deleting it.
    func suggestsDeleting(_ info: ConversationInfo) -> Bool {
        guard info.status == .unreviewed || info.status == .reviewed, results[info.id]?.notes.actionItemsDone == true else { return false }
        return (info.suggestDeletingAfter ?? .distantPast) <= Date()
    }

    func notNowForDeleting(_ id: String) {
        update(id) { $0.suggestDeletingAfter = Date().addingTimeInterval(Self.deletingAskedAgain) }
    }

    /// Runs `write`, which writes a Conversation's Notes again, at once, or once the user agrees when it would replace
    /// their changes to the Notes or which Action Items they checked off.
    func replaceNotes(of id: String, _ write: @escaping @MainActor () -> Void) {
        let result = results[id] ?? library.result(for: id)
        if result?.notesEdited == true || result?.notes.actionItems.contains(where: { $0.done == true }) == true {
            replacingNotes = NotesReplacement(id: id, write: write)
        } else {
            write()
        }
    }

    /// Gives a Conversation a title of the user's, in the list and in its Notes.
    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(id) {
            $0.title = title
            $0.renamed = true
        }
        guard var result = results[id] ?? library.result(for: id) else { return }
        result.notes.title = title
        do {
            try library.save(result, for: id)
            results[id] = result
        } catch {
            alert = "Couldn't save the title: \(error.localizedDescription)"
        }
    }

    func copyNotes(_ id: String) {
        guard let info = conversations.first(where: { $0.id == id }), let result = results[id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(NotesMarkdown.render(result.notes, startedAt: info.startedAt, endedAt: info.endedAt), forType: .string)
    }

    func delete(_ id: String) {
        guard id != recordingID, id != processingID else { return }
        waiting.removeAll { $0 == id }
        do {
            try library.delete(id)
        } catch {
            alert = "Couldn't delete the Conversation: \(error)"
        }
        results[id] = nil
        searchEntries[id] = nil
        flags[id] = nil
        liveTranscripts[id] = nil
        liveStopped.remove(id)
        if selection == id { selection = nil }
        conversations = library.all()
    }

    /// Reads the Conversations folder again, for Conversations added, changed, or removed outside the app; one left
    /// recording or processing there is processed, as at launch.
    func refresh() {
        conversations = library.all()
        let ids = Set(conversations.map(\.id))
        results = Dictionary(uniqueKeysWithValues: results.keys.filter(ids.contains).compactMap { id in library.result(for: id).map { (id, $0) } })
        flags = Dictionary(uniqueKeysWithValues: flags.keys.filter(ids.contains).map { ($0, library.flags(for: $0)) })
        if let selected = selection, !ids.contains(selected) { selection = nil }
        for info in conversations.reversed() where (info.status == .recording || info.status == .processing) && info.id != recordingID && info.id != processingID {
            enqueue(info.id)
        }
        indexConversations()
        AppLog.write("Read the Conversations folder again: \(conversations.count) Conversations")
    }

    // MARK: Asking

    /// Asks about a Conversation, answered from its Transcript with the user's fixes; nothing outside it.
    func ask(_ question: String, about id: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, askingID == nil, let result = results[id], let info = conversations.first(where: { $0.id == id }) else { return }
        let transcript = result.transcript.applying(flags[id] ?? library.flags(for: id))
        let earlier = (exchanges[id] ?? []).compactMap { exchange in exchange.answer.map { (question: exchange.question, answer: $0) } }
        exchanges[id, default: []].append(Exchange(question: question))
        askingID = id
        let assistant = self.assistant
        Task {
            let started = Date()
            var answer: Answer?
            var failure: String?
            do {
                answer = try await assistant.ask(
                    question, about: id, transcript: transcript, date: info.startedAt, language: result.transcript.language, after: earlier
                )
            } catch {
                failure = String(describing: error)
            }
            if let last = exchanges[id]?.indices.last {
                exchanges[id]?[last].answer = answer
                exchanges[id]?[last].failure = failure
            }
            askingID = nil
            let outcome = failure.map { "failed: \($0)" } ?? (answer?.text == nil ? "not in the Conversation" : "\(answer?.evidence.count ?? 0) quotes")
            AppLog.write(String(format: "%@: question answered in %.1f s (%@)", id, Date().timeIntervalSince(started), outcome))
            // The model takes about 16 GB; it stays loaded for follow-up questions, not for good.
            try? await Task.sleep(for: .seconds(300))
            await assistant.unload(ifIdleFor: 290)
        }
    }

    // MARK: Marking the Transcript

    func loadFlags(_ id: String) {
        if flags[id] == nil { flags[id] = library.flags(for: id) }
    }

    func toggleFlag(_ word: TranscriptWord, in id: String) {
        changeFlags(id) { $0.toggle(word) }
    }

    /// Marks words as said by `speaker`, each with the Speaker it was transcribed as.
    func assign(_ words: [(word: TranscriptWord, transcribedAs: String?)], to speaker: String, in id: String) {
        changeFlags(id) { flags in
            for item in words { flags.assign(item.word, to: speaker, transcribedAs: item.transcribedAs) }
        }
    }

    /// Records what was said instead of words in a row, as one phrase. An English term typed for a word transcribed in
    /// Hebrew letters also teaches the Vocabulary that spelling, so later Transcripts get it right; over several words,
    /// only when each got one typed word, since otherwise which spelling goes with which term is a guess.
    func correct(_ words: [TranscriptWord], as said: String, in id: String) {
        changeFlags(id) { $0.correct(words, as: said) }
        let parts = said.split(whereSeparator: \.isWhitespace).map(String.init)
        let pairs = words.count == 1 ? [(words[0], said)] : parts.count == words.count ? Array(zip(words, parts)) : []
        do {
            var learnedAny = false
            for (word, part) in pairs {
                guard let learned = try vocabularyStore.learn(transcribed: word.transcribed ?? word.text, correction: part) else { continue }
                learnedAny = true
                AppLog.write("Vocabulary learned \(learned.spelling) → \(learned.term)")
            }
            if learnedAny { vocabulary = vocabularyStore.load() }
        } catch {
            alert = "Couldn't save the Vocabulary: \(error.localizedDescription)"
        }
    }

    /// Marks words wrong, or takes every mark off them.
    func mark(_ words: [TranscriptWord], wrong: Bool, in id: String) {
        changeFlags(id) { $0.mark(words, wrong: wrong) }
    }

    // MARK: Vocabulary

    func addTerm(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !vocabulary.terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        changeVocabulary { $0.terms.append(term) }
    }

    /// Removes a term, with the spellings learned for it.
    func removeTerm(_ term: String) {
        changeVocabulary { vocabulary in
            vocabulary.terms.removeAll { $0 == term }
            vocabulary.spellings = vocabulary.spellings.filter { $0.value != term }
        }
    }

    func forgetSpelling(_ spelling: String) {
        changeVocabulary { $0.spellings[spelling] = nil }
    }

    private func changeVocabulary(_ change: (inout Vocabulary) -> Void) {
        var current = vocabularyStore.load()
        change(&current)
        do {
            try vocabularyStore.save(current)
            vocabulary = current
        } catch {
            alert = "Couldn't save the Vocabulary: \(error.localizedDescription)"
        }
    }

    func toggleSpeakerFlag(lineStartingAt start: Double, speaker: String, in id: String) {
        changeFlags(id) { $0.toggleSpeaker(lineStartingAt: start, speaker: speaker) }
    }

    func noteListened(until time: Double, in id: String) {
        guard time > (flags[id]?.listenedUntil ?? 0) else { return }
        changeFlags(id) { $0.listenedUntil = time }
    }

    private func changeFlags(_ id: String, _ change: (inout TranscriptFlags) -> Void) {
        var current = flags[id] ?? library.flags(for: id)
        change(&current)
        flags[id] = current
        do {
            try library.save(current, for: id)
        } catch {
            alert = "Couldn't save the marks: \(error.localizedDescription)"
        }
    }

    func showInFinder(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: id)])
    }

    // MARK: People

    func recordVoiceSample() async {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isRecording else { return }
        guard await MicrophoneRecorder.requestAccess() else {
            voiceSample = .failed("Bekitzur needs the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "bekitzur-voice-sample.m4a")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let microphone = MicrophoneRecorder()
        do {
            try microphone.start(writingTo: url)
        } catch {
            voiceSample = .failed("Couldn't record: \(error)")
            return
        }
        voiceSample = .recording(until: Date().addingTimeInterval(Self.voiceSampleSeconds))
        try? await Task.sleep(for: .seconds(Self.voiceSampleSeconds))
        microphone.stop()
        voiceSample = .learning
        do {
            let voiceprint = try await Self.learnVoiceprint(named: name, from: url)
            try VoiceprintStore(url: BekitzurPaths.voiceprints).save(voiceprint)
            voiceSample = .learned(name)
            AppLog.write("Voice sample learned")
        } catch {
            AppLog.write("Voice sample failed: \(error)")
            voiceSample = .failed(String(describing: error))
        }
        reloadPeople()
    }

    @concurrent
    private nonisolated static func learnVoiceprint(named name: String, from url: URL) async throws -> Voiceprint {
        try await ConversationProcessor.voiceprint(named: name, from: url)
    }

    func forget(_ name: String) {
        try? VoiceprintStore(url: BekitzurPaths.voiceprints).delete(named: name)
        reloadPeople()
    }

    private func reloadPeople() {
        people = ((try? VoiceprintStore(url: BekitzurPaths.voiceprints).load()) ?? []).map(\.name).sorted()
    }

    // MARK: Windows

    func showMainWindow(selecting id: String? = nil) {
        if let id { selection = id }
        mainWindow.show()
    }

    func showSettings() {
        if hasNewSettings {
            newSettingsShown = NewSetting.added
            hasNewSettings = false
            UserDefaults.standard.set(NewSetting.revision, forKey: "seenSettingsRevision")
        }
        settingsWindow.show()
    }

    private func update(_ id: String, _ change: (inout ConversationInfo) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        try? library.save(conversations[index])
    }
}

/// An AppKit window around a SwiftUI view, so the menu bar and notifications can open it.
///
/// The app has a Dock icon only while one of these windows is open; otherwise it lives in the menu bar.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private static var open = Set<ObjectIdentifier>()

    private let title: String
    private let autosaveName: String
    private let size: NSSize
    private let content: () -> AnyView
    private var window: NSWindow?

    init(title: String, autosaveName: String, size: NSSize, @ViewBuilder content: @escaping () -> some View) {
        self.title = title
        self.autosaveName = autosaveName
        self.size = size
        self.content = { AnyView(content()) }
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            let hosting = NSHostingController(rootView: content())
            hosting.sceneBridgingOptions = [.toolbars]
            window.contentViewController = hosting
            window.title = title
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName(autosaveName)
            self.window = window
        }
        Self.open.insert(ObjectIdentifier(self))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(ObjectIdentifier(self))
        if Self.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
