import BekitzurDomain
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel
    @ViewState private var newTitle = ""

    var body: some View {
        NavigationSplitView {
            // Above the list rather than in its safe area, where rows scroll under the notes and show through them.
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    RequirementsNote(model: model)
                    PermissionsNote(model: model)
                    ModelsNote(model: model)
                    UpdateNote(model: model)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                ConversationListHeader(model: model)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 2)
                conversationList
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importRecordings(urls) }
                return !urls.isEmpty
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
            .toolbar {
                ToolbarItemGroup {
                    RecordButton(model: model)
                    Button {
                        Task { await model.chooseRecordingsToImport() }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Import a recording made elsewhere, like a voice memo, or a Conversation exported from Bekitzur")
                }
            }
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
                Text("You've edited this Conversation's Notes or checked off its Action Items. Writing the Notes again replaces your changes and unchecks them.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showSettings()
                } label: {
                    Label {
                        Text("Settings")
                    } icon: {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if model.hasNewSettings { NewDot().offset(x: 2, y: -2) }
                            }
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
                .help(model.hasNewSettings ? "Settings has something new (⌘,)" : "Settings (⌘,)")
            }
        }
        .alert("Bekitzur", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task { await model.refreshPermissions() }
    }

    /// The Conversations the People menu and search leave.
    private var shownConversations: [ConversationInfo] {
        guard model.filter.isActive else { return model.conversations }
        return model.conversations.filter { model.filter.matches(title: $0.displayTitle, entry: model.searchEntries[$0.id]) }
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then each month, with its year when it isn't this one.
    private static func title(of section: DaySection) -> String {
        switch section {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .previous7Days: return String(localized: "Previous 7 Days")
        case .previous30Days: return String(localized: "Previous 30 Days")
        case .month(let first):
            if Calendar.current.isDate(first, equalTo: Date(), toGranularity: .year) {
                return first.formatted(.dateTime.month(.wide))
            }
            return first.formatted(.dateTime.month(.wide).year())
        }
    }

    private var conversationList: some View {
        List(selection: $model.selection) {
            ForEach(DaySection.group(shownConversations, date: \.startedAt, now: Date()), id: \.section) { group in
                Section(Self.title(of: group.section)) {
                    ForEach(group.items) { info in
                        VStack(alignment: .leading, spacing: 2) {
                            ConversationRow(
                                info: info,
                                people: (model.searchEntries[info.id]?.people ?? []).sorted(),
                                timeOnly: group.section == .today || group.section == .yesterday
                            )
                            if let excerpt = model.filter.excerpt(title: info.displayTitle, entry: model.searchEntries[info.id]) {
                                SearchExcerpt(excerpt: excerpt).padding(.leading, 16)
                            }
                        }
                        .tag(info.id)
                        .contextMenu {
                            Button("Rename…") { model.renaming = info.id }
                            Button("Export…") { Task { await model.export(info.id) } }
                                .disabled(info.status == .recording || info.status == .processing)
                            Button("Show in Finder") { model.showInFinder(info.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(info.id) }
                                .disabled(info.status == .recording || info.status == .processing)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations yet",
                    systemImage: "waveform",
                    description: Text("Record or import one above, or drop a recording or an exported Conversation here.")
                )
            } else if shownConversations.isEmpty {
                ContentUnavailableView(
                    "No matching Conversations",
                    systemImage: "magnifyingglass",
                    description: Text("A Conversation shows when everyone picked in People is in it and the search is in its title, Notes, or Transcript.")
                )
            }
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
    }
}

/// Record, or while recording Stop and how long it's been, in red with its name beside it: as an icon alone, Record went
/// unnoticed.
private struct RecordButton: View {
    let model: AppModel

    var body: some View {
        if let startedAt = model.recordingStartedAt {
            Button {
                model.stopRecording()
            } label: {
                Label {
                    HStack(spacing: 4) {
                        Text("Stop")
                        RecordingTimer(since: startedAt)
                    }
                } icon: {
                    Image(systemName: "stop.fill")
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.glassProminent)
            .tint(.red)
            .help("Stop recording and write the Notes")
        } else {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(model.voiceSample != .idle && !model.voiceSample.isFinished)
            .help("Record your microphone and what your Mac plays")
        }
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

/// A Conversation in the list: its title, when and how long, or what processing it is at, and who was in it.
struct ConversationRow: View {
    let info: ConversationInfo
    /// The people named in it, other than the user.
    let people: [String]
    /// Under Today and Yesterday the time is enough; further back, the day.
    let timeOnly: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: info.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.displayTitle)
                    .fontWeight(info.status == .unreviewed ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if info.status == .processing {
                        Text(ShownNames.step(info.step))
                    } else {
                        Text(when)
                        if info.status == .recording {
                            Text("·")
                            RecordingTimer(since: info.startedAt)
                        } else if let minutes = info.minutes {
                            Text("· \(minutes) min")
                        }
                    }
                    Spacer(minLength: 6)
                    if !people.isEmpty {
                        AvatarStack(names: people, size: 15)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var when: String {
        if timeOnly { return info.startedAt.formatted(date: .omitted, time: .shortened) }
        return info.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

extension ConversationInfo {
    var minutes: Int? {
        endedAt.map { max(1, Int($0.timeIntervalSince(startedAt) / 60)) }
    }
}

extension String {
    /// The direction of most of its words, by `TextDirection.of`; counting letters instead, a Hebrew sentence with a few
    /// long English terms would come out left to right.
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
