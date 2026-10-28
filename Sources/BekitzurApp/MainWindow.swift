import BekitzurDomain
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.conversations) { info in
                    ConversationRow(info: info)
                        .tag(info.id)
                        .contextMenu {
                            Button("Show in Finder") { model.showInFinder(info.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(info.id) }
                                .disabled(info.status == .recording || info.status == .processing)
                        }
                }
            }
            .overlay {
                if model.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations yet",
                        systemImage: "waveform",
                        description: Text("Start a recording from the toolbar or the menu bar, or drop a recording here to import it.")
                    )
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importRecordings(urls) }
                return !urls.isEmpty
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    PermissionsNote(model: model)
                    UpdateNote(model: model)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            if let id = model.selection, let info = model.conversations.first(where: { $0.id == id }) {
                ConversationDetail(model: model, info: info)
            } else {
                ContentUnavailableView("Select a Conversation", systemImage: "text.bubble")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.chooseRecordingsToImport() }
                } label: {
                    Label("Import recording", systemImage: "square.and.arrow.down")
                }
                .help("Import a recording made elsewhere, like a voice memo")
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isRecording {
                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop and write Notes", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        Task { await model.startRecording() }
                    } label: {
                        Label("Start recording", systemImage: "record.circle")
                    }
                }
            }
        }
        .alert("Bekitzur", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task { await model.refreshPermissions() }
    }
}

/// How long the recording has been going, ticking every second, in the same form as the live Transcript's times.
struct RecordingTimer: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(timestamp(max(0, context.date.timeIntervalSince(since)))).monospacedDigit()
        }
    }
}

struct ConversationRow: View {
    let info: ConversationInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: info.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayTitle)
                    .fontWeight(info.status == .unreviewed ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(info.startedAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    if info.status == .recording {
                        Text("·")
                        RecordingTimer(since: info.startedAt)
                    } else if let minutes = info.minutes {
                        Text("· \(minutes) min")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if info.status == .processing {
                    Text(info.step ?? "Processing").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

extension ConversationInfo {
    var minutes: Int? {
        endedAt.map { max(1, Int($0.timeIntervalSince(startedAt) / 60)) }
    }
}

extension String {
    /// More Hebrew (or other right-to-left) letters than Latin ones.
    var isMostlyRightToLeft: Bool {
        var rightToLeft = 0, leftToRight = 0
        for scalar in unicodeScalars where scalar.properties.isAlphabetic {
            if (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFEFF).contains(scalar.value) {
                rightToLeft += 1
            } else {
                leftToRight += 1
            }
        }
        return rightToLeft > leftToRight
    }
}

/// Text laid out right to left when it's mostly Hebrew, so mixed Hebrew and English reads in the right order.
struct DirectionalText: View {
    let text: String
    let rightToLeft: Bool

    init(_ text: String, rightToLeft: Bool? = nil) {
        self.text = text
        self.rightToLeft = rightToLeft ?? text.isMostlyRightToLeft
    }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// SwiftUI's `@State` is a macro on macOS 26 whose plugin ships only with Xcode. This names the property wrapper underneath,
/// so the app builds with the Command Line Tools alone.
typealias ViewState = SwiftUI.State

func timestamp(_ seconds: Double?) -> String {
    guard let seconds else { return "" }
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
