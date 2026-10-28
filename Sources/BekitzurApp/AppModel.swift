import AppKit
import AVFoundation
import BekitzurCapture
import BekitzurDomain
import BekitzurLibrary
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
    private(set) var results: [String: ProcessedConversation] = [:]
    /// What the user marked in each Transcript while listening back.
    private(set) var flags: [String: TranscriptFlags] = [:]
    /// The user's own English terms and the spellings their corrections taught.
    private(set) var vocabulary: Vocabulary
    private(set) var people: [String] = []
    @ObservationIgnored let vocabularyStore = VocabularyStore(url: BekitzurPaths.vocabulary)
    private(set) var recordingID: String?
    private(set) var recordingStartedAt: Date?
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
    /// A newer version, once a check found one.
    private(set) var availableUpdate: UpdateManifest?
    /// What the updater is doing, while it checks or downloads.
    private(set) var updateStep: String?
    @ObservationIgnored private let updater = Updater(
        feed: Bundle.main.object(forInfoDictionaryKey: "BekitzurUpdateFeed") as? String,
        publicKey: Bundle.main.object(forInfoDictionaryKey: "BekitzurUpdatePublicKey") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
    @ObservationIgnored private var notifiedUpdate: String?
    var selection: String?
    var alert: String?

    var language: ConversationLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    var userName: String {
        didSet { UserDefaults.standard.set(userName, forKey: "userName") }
    }

    @ObservationIgnored private var recorder: ConversationRecorder?
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
        language = UserDefaults.standard.string(forKey: "language").flatMap(ConversationLanguage.init(rawValue:)) ?? .hebrew
        userName = UserDefaults.standard.string(forKey: "userName") ?? NSFullUserName()
        vocabulary = VocabularyStore(url: BekitzurPaths.vocabulary).load()
        try? FileManager.default.createDirectory(at: BekitzurPaths.conversations, withIntermediateDirectories: true)
        conversations = library.all()
        reloadPeople()
        // The app quit while these were recording or processing; their audio is on disk, so process it now.
        for info in conversations.reversed() where info.status == .recording || info.status == .processing {
            enqueue(info.id)
        }
        // Coming back from System Settings makes the app active.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshPermissions() }
        }
        Task { await refreshPermissions() }
        Task(priority: .utility) { await lineUpEarlierCalls() }
        Updater.removeLeftovers(beside: Bundle.main.bundleURL)
        Task { await checkForUpdatesRegularly() }
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
        AppLog.write("Downloading update \(manifest.version)")
        Task {
            do {
                let app = try await updater.download(manifest)
                updateStep = nil
                // A recording may have started during the download.
                if !wasBusy, isRecording || processingID != nil, !allowInterruption() { return }
                try Updater.replace(Bundle.main.bundleURL, with: app)
                AppLog.write("Installed update \(manifest.version); restarting")
                relaunch()
            } catch {
                updateStep = nil
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

    /// Calls recorded before tracks were lined up while recording: measures once how much later each one's microphone
    /// plays, for playback and processing.
    private func lineUpEarlierCalls() async {
        for info in conversations where info.microphoneDelay == nil && info.status != .recording && info.status != .processing {
            let tracks = library.audioTracks(for: info.id)
            let named = { (track: ConversationRecorder.Track) in tracks.first { $0.deletingPathExtension().lastPathComponent == track.name } }
            guard let microphone = named(.microphone), let system = named(.systemAudio) else { continue }
            let delay = await Self.measureMicrophoneDelay(microphone: microphone, system: system)
            guard conversations.first(where: { $0.id == info.id })?.microphoneDelay == nil else { continue }
            update(info.id) { $0.microphoneDelay = delay }
            AppLog.write(String(format: "%@: microphone track lined up, played %.0f ms later", info.id, delay * 1000))
        }
    }

    @concurrent
    private nonisolated static func measureMicrophoneDelay(microphone: URL, system: URL) async -> Double {
        ((try? ConversationProcessor.microphoneDelay(microphone: microphone, system: system)) ?? nil) ?? 0
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
        if isRecording { return "record.circle.fill" }
        if processingID != nil { return "hourglass" }
        return nil
    }

    // MARK: Recording

    /// Live chunks are transcribed by a helper process, this app run with `Entry.liveTranscriptionArgument`, so a crash
    /// in whisper.cpp ends only live transcription; one took the whole app down mid-recording.
    static let transcribesLive = true

    func startRecording() async {
        guard recordingID == nil else { return }
        guard await MicrophoneRecorder.requestAccess() else {
            AppLog.write("Recording not started: microphone permission \(MicrophoneRecorder.permission)")
            alert = "Bekitzur needs the microphone. Allow it in System Settings → Privacy & Security → Microphone, then try again."
            await refreshPermissions()
            return
        }
        do {
            var info = try library.create(language: language)
            info.microphoneDelay = 0
            try library.save(info)
            let id = info.id
            var live: LiveTranscriber?
            if Self.transcribesLive, let app = Bundle.main.executableURL {
                let helper = HelperChunkTranscriber(
                    executable: app,
                    arguments: [Entry.liveTranscriptionArgument, BekitzurPaths.speechModel(for: info.language).path, info.language.rawValue]
                )
                live = LiveTranscriber(
                    language: info.language,
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
            liveTranscriber = live
            recordingID = info.id
            recordingStartedAt = info.startedAt
            conversations = library.all()
            selection = info.id
            AppLog.write("\(info.id): recording started (\(info.language.name))")
        } catch {
            AppLog.write("Recording not started: \(error)")
            alert = "Couldn't start recording: \(error)"
        }
    }

    func stopRecording() {
        guard let id = recordingID, let recorder else { return }
        recorder.stop()
        AppLog.write("\(id): recording stopped after \(Int(Date().timeIntervalSince(recordingStartedAt ?? Date()))) s")
        let silence = recorder.leadingSilence
        AppLog.write(String(format: "%@: tracks lined up; system audio started after %.0f ms, the microphone after %.0f ms",
                            id, (silence[.systemAudio] ?? 0) * 1000, (silence[.microphone] ?? 0) * 1000))
        self.recorder = nil
        recordingID = nil
        recordingStartedAt = nil
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

    /// The helper process ended or a chunk couldn't be transcribed; the recording goes on, and its files are transcribed
    /// once it stops.
    private func liveFailed(_ id: String) {
        AppLog.write("\(id): live transcription stopped; the recording continues and will be transcribed from its files")
        liveStopped.insert(id)
    }

    /// Updates the live Transcript while recording; later updates are covered by `finishLive`.
    private func transcribedLive(_ transcript: Transcript, for id: String) {
        guard id == recordingID else { return }
        if liveTranscripts[id] == nil { AppLog.write("\(id): live Transcript started") }
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

    /// Finishes the audio files so the Conversation is processed on the next launch.
    func stopRecordingForQuit() {
        guard let id = recordingID else { return }
        liveTranscriber?.cancel()
        liveTranscriber = nil
        recorder?.stop()
        AppLog.write("\(id): recording stopped by quitting; it will be processed on the next launch")
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

    /// Transcribes the Recording again. Marks on the old Transcript's words are dropped, since its words are gone.
    func transcribeAgain(_ id: String, language: ConversationLanguage) {
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
        let saved = library.liveTranscript(for: id).flatMap { $0.transcript.language == info.language ? $0 : nil }
        // A live Transcript finished after the recording stopped saves transcribing the files; an unfinished one is only
        // used if the files can't be read.
        let live = kept == nil && notesOnly == nil && saved?.complete == true ? saved?.transcript : nil
        let salvage = notesOnly == nil ? saved?.transcript : nil
        let transcript = kept ?? live
        let flags = self.flags[id] ?? library.flags(for: id)
        let how = notesOnly != nil ? "Notes only" : kept != nil ? "same Transcript" : live != nil ? "live Transcript" : "new Transcript"
        AppLog.write("\(id): processing (\(info.language.name)\(info.people.map { ", \($0) people" } ?? ""), \(how), \(flags.fixes.count) fixes)")
        Task {
            do {
                let result: ProcessedConversation
                let warning: String?
                let measuredDelay: Double?
                if let notesOnly {
                    result = try await Self.rewrite(notesOnly, flags: flags, date: info.startedAt, language: info.language) { step in
                        Task { @MainActor in
                            AppModel.shared.update(id) { if $0.status == .processing { $0.step = step.rawValue } }
                        }
                    }
                    warning = info.warning
                    measuredDelay = nil
                } else {
                    (result, warning, measuredDelay) = try await Self.run(
                        folder: folder,
                        date: info.startedAt,
                        language: info.language,
                        people: info.people,
                        microphoneDelay: info.microphoneDelay,
                        transcript: transcript,
                        salvage: salvage,
                        flags: flags
                    ) { step in
                        AppLog.write(String(format: "%@: %@ (%.0f s)", id, step.rawValue, Date().timeIntervalSince(started)))
                        Task { @MainActor in
                            AppModel.shared.update(id) { if $0.status == .processing { $0.step = step.rawValue } }
                        }
                    }
                }
                try library.save(result, for: id)
                library.deleteLiveTranscript(for: id)
                liveTranscripts[id] = nil
                liveStopped.remove(id)
                results[id] = result
                update(id) {
                    $0.status = .unreviewed
                    $0.step = nil
                    $0.title = result.notes.title
                    $0.warning = warning
                    if let measuredDelay { $0.microphoneDelay = measuredDelay }
                }
                if let measuredDelay { AppLog.write(String(format: "%@: microphone track lined up, played %.0f ms later", id, measuredDelay * 1000)) }
                let notes = result.notes
                AppLog.write(String(
                    format: "%@: Notes ready after %.0f s: %d Speakers, %d Decisions, %d Action Items, %d Open Questions",
                    id, Date().timeIntervalSince(started), result.speakers.count, notes.decisions.count, notes.actionItems.count, notes.openQuestions.count
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
    ///   - microphoneDelay: How much later to play the microphone track; measured here when nil, and returned.
    ///   - salvage: A live Transcript to write the Notes from if the audio can't be read, as when the app quit before it
    ///     finished the files.
    @concurrent
    private nonisolated static func run(
        folder: URL,
        date: Date,
        language: ConversationLanguage,
        people: Int?,
        microphoneDelay: Double?,
        transcript: Transcript?,
        salvage: Transcript?,
        flags: TranscriptFlags,
        progress: @escaping @Sendable (ProcessingStep) -> Void
    ) async throws -> (result: ProcessedConversation, warning: String?, measuredDelay: Double?) {
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
                language: language,
                progress: progress
            )
            let minutes = Int(((salvage.segments.last?.end ?? 0) / 60).rounded(.up))
            return (result, "The audio couldn't be read because the app quit before finishing it, so these Notes come from the live Transcript of the first \(minutes) minutes, without Speakers.", nil)
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
        var transcript = transcript
        if transcript?.language != language {
            progress(.transcribing)
            transcript = try await transcribeInHelper(samples, language: language)
        }
        let voiceprints = (try? VoiceprintStore(url: BekitzurPaths.voiceprints).load()) ?? []
        let result = try await ConversationProcessor.process(
            samples,
            date: date,
            language: language,
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
        return (result, warning, measuredDelay)
    }

    /// Transcribes a whole Recording as live transcription does, in the helper process: a crash in whisper.cpp then fails
    /// this Conversation instead of the app, and the app's every launch after it, since unfinished Conversations resume.
    private nonisolated static func transcribeInHelper(_ samples: [Float], language: ConversationLanguage) async throws -> Transcript {
        guard let app = Bundle.main.executableURL else { throw ProcessingError.transcriptionStopped }
        let helper = HelperChunkTranscriber(
            executable: app,
            arguments: [Entry.liveTranscriptionArgument, BekitzurPaths.speechModel(for: language).path, language.rawValue]
        )
        let live = LiveTranscriber(language: language, chunks: helper, tracks: 1) { _ in }
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

    /// Asks for recordings to import, with the language they're in.
    func chooseRecordingsToImport() async {
        let panel = NSOpenPanel()
        panel.title = "Import recordings"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        let languages = NSPopUpButton()
        languages.addItems(withTitles: ConversationLanguage.allCases.map(\.name))
        languages.selectItem(at: ConversationLanguage.allCases.firstIndex(of: language) ?? 0)
        let people = NSPopUpButton()
        people.addItems(withTitles: Self.peopleChoices.map(Self.peopleTitle))
        let accessory = NSStackView(views: [
            NSTextField(labelWithString: "Language:"), languages,
            NSTextField(labelWithString: "People who spoke:"), people,
        ])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        NSApp.activate()
        guard await panel.begin() == .OK else { return }
        await importRecordings(
            panel.urls,
            language: ConversationLanguage.allCases[languages.indexOfSelectedItem],
            people: Self.peopleChoices[people.indexOfSelectedItem]
        )
    }

    /// "Let Bekitzur decide", then 2 to 8 people.
    static let peopleChoices: [Int?] = [nil] + Array(2...8)

    static func peopleTitle(_ people: Int?) -> String {
        people.map { "\($0) people" } ?? "Let Bekitzur decide"
    }

    /// Copies recordings into new Conversations and processes them. A Conversation is dated from the recording's
    /// metadata when it has a date, since due dates like "tomorrow" are counted from it, and from the file otherwise.
    func importRecordings(_ urls: [URL], language: ConversationLanguage? = nil, people: Int? = nil) async {
        let language = language ?? self.language
        for url in urls {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let recorded = try? await asset.load(.creationDate)?.load(.dateValue)
                let fileDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                let startedAt = recorded ?? fileDate ?? Date()
                var info = try library.create(language: language, startedAt: startedAt)
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
                AppLog.write("\(info.id): imported \(url.lastPathComponent) (\(Int(duration)) s, \(language.name), dated \(recorded == nil ? "from the file" : "from its metadata"))")
                enqueue(info.id)
            } catch {
                AppLog.write("Import of \(url.lastPathComponent) failed: \(error)")
                alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
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
        flags[id] = nil
        liveTranscripts[id] = nil
        liveStopped.remove(id)
        if selection == id { selection = nil }
        conversations = library.all()
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
                    question, about: id, transcript: transcript, date: info.startedAt, language: info.language, after: earlier
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

    /// Records what was said instead of a word. An English term typed for a word transcribed in Hebrew letters also
    /// teaches the Vocabulary that spelling, so later Transcripts get it right.
    func correct(_ word: TranscriptWord, as said: String, in id: String) {
        changeFlags(id) { $0.correct(word, as: said) }
        do {
            if let learned = try vocabularyStore.learn(transcribed: word.transcribed ?? word.text, correction: said) {
                vocabulary = vocabularyStore.load()
                AppLog.write("Vocabulary learned \(learned.spelling) → \(learned.term)")
            }
        } catch {
            alert = "Couldn't save the Vocabulary: \(error.localizedDescription)"
        }
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
