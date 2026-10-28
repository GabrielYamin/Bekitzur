import BekitzurDomain
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionsNote(model: model)
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
                .buttonStyle(.plain)
                .help("Show the live Transcript")
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop and write Notes", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.voiceSample != .idle && !model.voiceSample.isFinished)
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
                            Text(info.startedAt, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            Button("Import recording…") {
                model.showMainWindow()
                Task { await model.chooseRecordingsToImport() }
            }
            .buttonStyle(.plain)
            if model.canUpdate {
                Button(model.updateStep ?? "Check for Updates…") { Task { await model.checkForUpdates(manually: true) } }
                    .buttonStyle(.plain)
                    .disabled(model.updateStep != nil)
            }
            HStack {
                Button("Open Bekitzur") { model.showMainWindow() }
                Button("Settings…") { model.showSettings() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
