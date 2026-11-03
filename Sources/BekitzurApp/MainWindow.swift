import BekitzurDomain
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel
    @ViewState private var newTitle = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.conversations) { info in
                    ConversationRow(info: info)
                        .tag(info.id)
                        .contextMenu {
                            Button("Rename…") { model.renaming = info.id }
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
                        description: Text("Record or import one above, or drop a recording here.")
                    )
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importRecordings(urls) }
                return !urls.isEmpty
            }
            .alert("Rename Conversation", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let id = model.renaming { model.rename(id, to: newTitle) }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.renaming) { _, id in
                newTitle = id.flatMap { id in model.conversations.first { $0.id == id }?.displayTitle } ?? ""
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    PermissionsNote(model: model)
                    ModelsNote(model: model)
                    UpdateNote(model: model)
                    StartButtons(model: model)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            Group {
                if let id = model.selection, let info = model.conversations.first(where: { $0.id == id }) {
                    ConversationDetail(model: model, info: info)
                } else {
                    ContentUnavailableView("Select a Conversation", systemImage: "text.bubble")
                }
            }
            .alert("Replace your changes to the Notes?", isPresented: Binding(get: { model.replacingNotes != nil }, set: { if !$0 { model.replacingNotes = nil } })) {
                Button("Write Notes Again", role: .destructive) {
                    let replacement = model.replacingNotes
                    model.replacingNotes = nil
                    replacement?.write()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You've edited this Conversation's Notes. Writing them again replaces your changes.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Read the Conversations folder again, for Conversations added or changed outside Bekitzur (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
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

/// Recording and importing, each in a box of its own at the top of the list; as toolbar icons, people didn't find them.
private struct StartButtons: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let startedAt = model.recordingStartedAt {
                BoxButton(title: "Stop", systemImage: "stop.fill", tint: .red) {
                    model.stopRecording()
                } subtitle: {
                    HStack(spacing: 4) {
                        Text("Recording")
                        RecordingTimer(since: startedAt)
                    }
                }
                .help("Stop recording and write the Notes")
            } else {
                BoxButton(title: "Record", systemImage: "record.circle", tint: .red) {
                    Task { await model.startRecording() }
                } subtitle: {
                    Text("A call or a meeting")
                }
                .disabled(model.voiceSample != .idle && !model.voiceSample.isFinished)
                .help("Record your microphone and what your Mac plays")
            }
            BoxButton(title: "Import", systemImage: "square.and.arrow.down", tint: .accentColor) {
                Task { await model.chooseRecordingsToImport() }
            } subtitle: {
                Text("A recording from elsewhere")
            }
            .help("Import a recording made elsewhere, like a voice memo")
        }
    }
}

private struct BoxButton<Subtitle: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @ViewBuilder let subtitle: Subtitle
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: systemImage).font(.title2).foregroundStyle(tint)
                Text(title).font(.headline)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(10)
            .background(tint.opacity(hovering && isEnabled ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
    /// The direction of most of its words, by `TextDirection.of`; counting letters instead, a Hebrew sentence with a few
    /// long English terms came out left to right.
    func direction(fallback: TextDirection) -> TextDirection {
        TextDirection.of(split(whereSeparator: \.isWhitespace), fallback: fallback)
    }

    var isMostlyRightToLeft: Bool {
        direction(fallback: .leftToRight) == .rightToLeft
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
