import BekitzurDomain
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequirementsNote(model: model)
            PermissionsNote(model: model)
            ModelsNote(model: model)
            UpdateNote(model: model)
            if let startedAt = model.recordingStartedAt {
                Button {
                    model.showMainWindow(selecting: model.recordingID)
                } label: {
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("Recording")
                        Spacer()
                        RecordingTimer(since: startedAt)
                    }
                    .font(.headline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelRowStyle())
                .help("Show the live Transcript")
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
            } else {
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
                .controlSize(.large)
                .disabled(model.voiceSample != .idle && !model.voiceSample.isFinished)
                .hoverLight()
                if model.microphones.count > 1 {
                    Menu {
                        Picker("Microphone", selection: Binding(get: { model.microphoneUID }, set: { model.microphoneUID = $0 })) {
                            microphoneChoices(model)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.recordingMicrophone?.name ?? "Microphone", systemImage: "mic")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The microphone recordings use")
                }
            }

            if let processing = model.processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(processing.step ?? "Processing")…").foregroundStyle(.secondary)
                }
            }

            if let alert = model.alert {
                Text(alert).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            let recent = model.conversations.filter { $0.status != .recording }.prefix(5)
            if !recent.isEmpty {
                Divider()
                ForEach(recent) { info in
                    Button {
                        model.showMainWindow(selecting: info.id)
                    } label: {
                        HStack {
                            StatusDot(status: info.status)
                            Text(info.displayTitle).lineLimit(1)
                            Spacer()
                            Text(info.displayDate).foregroundStyle(.secondary).fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelRowStyle())
                }
            }

            Divider()
            Button("Import recording…") {
                model.showMainWindow()
                Task { await model.chooseRecordingsToImport() }
            }
            .buttonStyle(PanelRowStyle())
            if model.canUpdate {
                Button(model.updateStep ?? "Check for Updates…") { Task { await model.checkForUpdates(manually: true) } }
                    .buttonStyle(PanelRowStyle())
                    .disabled(model.updateStep != nil)
            }
            HStack {
                Button("Open Bekitzur") { model.showMainWindow() }
                    .hoverLight()
                Button("Settings…") { model.showSettings() }
                    .hoverLight()
                    .overlay(alignment: .topTrailing) {
                        if model.hasNewSettings { NewDot().offset(x: 3, y: -3) }
                    }
                    .help(model.hasNewSettings ? "Settings has something new" : "")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .hoverLight()
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.refreshPermissions() }
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
        case .recording: "Recording…"
        case .processing: "Processing…"
        case .failed: "Couldn't write Notes"
        default: "Conversation"
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
        case .recording: "Recording"
        case .processing: "Processing"
        case .unreviewed: "Not reviewed yet"
        case .reviewed: "Reviewed"
        case .failed: "Failed"
        }
    }
}
