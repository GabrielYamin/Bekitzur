import BekitzurDomain
import SwiftUI

/// The panel under Bekitzur's icon in the menu bar: the quickest way to record, and to see what's going on. While
/// recording, the time, both levels, a note at this moment, the notes so far, the last live line, and Stop; otherwise
/// Record, what's being processed, and the recent Conversations.
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRecording {
                RecordingHeader(model: model)
            } else {
                IdleHeader(model: model)
            }
            RequirementsNote(model: model)
            PermissionsNote(model: model)
            ModelsNote(model: model)
            UpdateNote(model: model)
            if model.isRecording {
                RecordingPanel(model: model)
            } else {
                IdlePanel(model: model)
            }
            if let alert = model.alert {
                Text(alert).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            MenuFooter(model: model)
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.refreshPermissions() }
    }
}

private struct IdleHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "Bekitzur").font(.headline)
            Spacer()
            if model.microphones.count > 1 {
                Menu {
                    Picker("Microphone", selection: Binding(get: { model.microphoneUID }, set: { model.microphoneUID = $0 })) {
                        microphoneChoices(model)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.recordingMicrophone?.name ?? String(localized: "Microphone"), systemImage: "mic")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The microphone recordings use")
            }
        }
    }
}

private struct RecordingHeader: View {
    let model: AppModel

    var body: some View {
        Button {
            model.showMainWindow(selecting: model.recordingID)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording").font(.headline)
                if let app = model.recordedCall {
                    Text("\(app) call").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let startedAt = model.recordingStartedAt {
                    RecordingTimer(since: startedAt).font(.headline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the recording in Bekitzur")
    }
}

private struct IdlePanel: View {
    let model: AppModel

    var body: some View {
        if let app = model.callToRecord {
            Label("\(app) is using the microphone.", systemImage: "phone")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Button {
            Task { await model.startRecording() }
        } label: {
            Label(model.callToRecord == nil ? "Start recording" : "Record this call", systemImage: "record.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(model.voiceSample != .idle && !model.voiceSample.isFinished)
        .hoverLight()
        if let processing = model.processing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: "\(ShownNames.step(processing.step)) · \(processing.displayTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        let recent = model.conversations.filter { $0.status != .recording }.prefix(4)
        if !recent.isEmpty {
            Divider()
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(recent) { info in
                Button {
                    model.showMainWindow(selecting: info.id)
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(status: info.status)
                        Text(info.displayTitle).lineLimit(1)
                        Spacer()
                        AvatarStack(names: (model.searchEntries[info.id]?.people ?? []).sorted(), size: 14)
                        Text(info.displayDate).font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelRowStyle())
            }
        }
    }
}

private struct RecordingPanel: View {
    let model: AppModel

    var body: some View {
        let id = model.recordingID ?? ""
        let notes = (model.yourNotes[id] ?? []).filter { !$0.words.isEmpty }
        HStack(spacing: 16) {
            LevelBars(symbol: "mic.fill", levels: model.levels.microphone)
            LevelBars(symbol: "speaker.wave.2.fill", levels: model.levels.systemAudio)
        }
        MenuNoteField(model: model)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your notes")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                ForEach(notes.suffix(3)) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timestamp(note.at)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        DirectionalText(note.words).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        if let line = model.liveTranscripts[id]?.segments.last {
            VStack(alignment: .leading, spacing: 3) {
                Text("Live, about half a minute behind").font(.caption).foregroundStyle(.tertiary)
                DirectionalText(line.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        if let app = model.endedCall {
            Label("\(app) stopped using the microphone. Did the call end?", systemImage: "phone.down")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button {
            model.stopRecording()
        } label: {
            Label("Stop and write Notes", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .hoverLight()
    }
}

/// A note at this moment, typed in the panel: the moment is when typing starts, and Return adds it.
private struct MenuNoteField: View {
    let model: AppModel
    @ViewState private var text = ""
    @ViewState private var at: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(.tint)
            TextField("Note", text: $text, prompt: Text("Add a note at \(timestamp(at ?? Double(model.recordingSeconds)))"))
                .textFieldStyle(.plain)
                .onChange(of: text) {
                    if text.isEmpty {
                        at = nil
                    } else if at == nil {
                        at = elapsed
                    }
                }
                .onSubmit {
                    model.addQuickNote(text, at: at ?? elapsed)
                    text = ""
                }
            Text(model.quickNoteShortcut.shown).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }

    private var elapsed: Double {
        Date().timeIntervalSince(model.recordingStartedAt ?? Date())
    }
}

private struct MenuFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Open Bekitzur") { model.showMainWindow(selecting: model.recordingID) }
                .hoverLight()
            Button {
                model.showMainWindow()
                Task { await model.chooseRecordingsToImport() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Import a recording")
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .overlay(alignment: .topTrailing) {
                if model.hasNewSettings { NewDot().offset(x: 3, y: -3) }
            }
            .help(model.hasNewSettings ? "Settings has something new" : "Settings")
            if model.canUpdate {
                Button {
                    Task { await model.checkForUpdates(manually: true) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(model.updateStep != nil)
                .help(model.updateStep ?? String(localized: "Check for Updates…"))
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .hoverLight()
        }
    }
}

extension VoiceSample {
    var isFinished: Bool {
        switch self {
        case .idle, .learned, .failed: true
        case .recording, .learning: false
        }
    }
}

extension ConversationInfo {
    var displayTitle: String {
        if let title { return title }
        return switch status {
        case .recording: String(localized: "Recording…")
        case .processing: String(localized: "Processing…")
        case .failed: String(localized: "Couldn't write Notes")
        default: String(localized: "Conversation")
        }
    }

    var displayDate: String {
        startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

struct StatusDot: View {
    let status: ConversationStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(help)
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .processing: .yellow
        case .unreviewed: .accentColor
        case .reviewed: .clear
        case .failed: .orange
        }
    }

    private var help: String {
        switch status {
        case .recording: String(localized: "Recording")
        case .processing: String(localized: "Processing")
        case .unreviewed: String(localized: "Not reviewed yet")
        case .reviewed: String(localized: "Reviewed")
        case .failed: String(localized: "Failed")
        }
    }
}
