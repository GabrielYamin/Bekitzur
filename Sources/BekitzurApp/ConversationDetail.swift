import BekitzurDomain
import SwiftUI

struct ConversationDetail: View {
    let model: AppModel
    let info: ConversationInfo
    @ViewState private var tab = Tab.notes
    @ViewState private var playback = PlaybackModel()
    @ViewState private var confirmingDelete = false

    enum Tab: Hashable {
        case notes, transcript, speakers, chat
    }

    private var result: ProcessedConversation? { model.results[info.id] }

    /// People who talked at once are being separated, after the Notes, and nothing is waiting to be shown yet.
    private var isSeparating: Bool {
        guard info.separating == true, model.separationsFound[info.id] == nil else { return false }
        return info.status == .unreviewed || info.status == .reviewed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The split view keeps the detail at least as tall as its minimum, measured at the narrowest width, where
            // text wraps word by word and can come out taller than the window, pushing the bottom out of sight.
            content.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .task(id: "\(info.id)-\(info.status)") {
            model.loadResult(info.id)
            model.loadFlags(info.id)
            model.loadYourNotes(info.id)
        }
        // Reloaded when the status changes, since processing turns the recorded .aac tracks into .m4a files, and once a
        // call's tracks are lined up.
        .task(id: "\(info.id)-\(info.status)-\(info.microphoneDelay ?? -1)-\(info.systemAudioDelays?.hashValue ?? -1)") {
            if info.status == .recording || info.status == .processing {
                playback.stop()
            } else {
                await playback.load(
                    model.library.audioTracks(for: info.id),
                    microphoneDelay: info.microphoneDelay ?? 0,
                    systemAudioDelays: info.systemAudioDelays ?? []
                )
            }
        }
        .onDisappear { playback.stop() }
        .confirmationDialog("Delete \u{201C}\(info.displayTitle)\u{201D}?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete(info.id) }
        } message: {
            Text("Its recording, Transcript, and Notes are deleted from this Mac. This can't be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.displayTitle).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 8) {
                if !people.isEmpty {
                    AvatarStack(names: people, size: 18, limit: 5)
                    Text(verbatim: ListFormatter.localizedString(byJoining: people.map(ShownNames.speaker)))
                    Text(verbatim: "·")
                }
                Text(subtitle)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if isSeparating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Separating people who talk at once…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("What people said over each other comes into the Transcript when it's done; everything else is ready.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Who the Conversation's Speakers are, named or not, each once.
    private var people: [String] {
        var seen = Set<String>()
        return (result?.speakers ?? []).map(\.displayName).filter { seen.insert($0).inserted }
    }

    /// The four views in the middle of the toolbar, and on its right what's done with the whole Conversation.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let result, info.status == .unreviewed || info.status == .reviewed {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Notes").tag(Tab.notes)
                    Text("Transcript").tag(Tab.transcript)
                    Text(speakersTabTitle(result)).tag(Tab.speakers)
                    Text("Chat (beta)").tag(Tab.chat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if result != nil {
                Menu {
                    Button("Copy Notes") { model.copyNotes(info.id) }
                    Button("Copy Transcript") { model.copyTranscript(info.id) }
                    Divider()
                    Button("Export…") { Task { await model.export(info.id) } }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Copy the Notes or the Transcript, or export the Conversation")
                if info.status == .unreviewed {
                    Button {
                        model.markReviewed(info.id)
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Done reviewing")
                }
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if info.status == .reviewed {
                Button("Mark as not reviewed") { model.markUnreviewed(info.id) }
            }
            if info.status == .unreviewed || info.status == .reviewed || info.status == .failed {
                Button("Write Notes again") { model.replaceNotes(of: info.id) { model.writeNotesAgain(info.id) } }
                Button("Transcribe again") { model.replaceNotes(of: info.id) { model.transcribeAgain(info.id, language: info.language) } }
                ForEach(ConversationLanguage.allCases.filter { $0 != info.language }, id: \.self) { language in
                    Button("Transcribe again as \(ShownNames.language(language))") { model.replaceNotes(of: info.id) { model.transcribeAgain(info.id, language: language) } }
                }
            }
            Button("Rename…") { model.renaming = info.id }
            Button("Export…") { Task { await model.export(info.id) } }
                .disabled(info.status == .recording || info.status == .processing)
            Button("Show in Finder") { model.showInFinder(info.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(info.id) }
                .disabled(info.status == .recording || info.status == .processing)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }

    private var subtitle: String {
        var parts = [info.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())]
        if let minutes = info.minutes { parts.append(String(localized: "\(minutes) min")) }
        if let language = info.language {
            parts.append(ShownNames.language(language))
        } else if info.status == .recording {
            parts.append(String(localized: "Detecting the language"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch info.status {
        case .recording:
            VStack(spacing: 0) {
                if let silent = model.silentMicrophone, info.id == model.recordingID {
                    QuietNotice(
                        String(localized: "No sound is coming from \(silent), even after starting it again. Your voice isn't being recorded."),
                        systemImage: "mic.slash.fill",
                        tint: .orange
                    ) {
                        AnotherMicrophone(model: model)
                    }
                    .padding(.bottom, 8)
                }
                RecordingView(model: model, info: info)
            }
        case .processing where model.liveTranscripts[info.id] != nil || model.yourNotes[info.id]?.contains(where: { !$0.words.isEmpty }) == true:
            RecordingView(model: model, info: info)
        case .processing:
            ContentUnavailableView {
                Label(ShownNames.step(info.step), systemImage: "hourglass")
            } description: {
                Text("Everything runs on this Mac. An hour-long Conversation takes a few minutes.")
            } actions: {
                ProgressView()
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't write Notes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(info.error ?? "")
            } actions: {
                Button("Try again") { model.transcribeAgain(info.id, language: info.language) }
            }
        case .unreviewed, .reviewed:
            if let result {
                VStack(spacing: 0) {
                    if let warning = info.warning {
                        QuietNotice(NotesWarning(saved: warning)?.shown ?? warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if model.notesAreBehind(info.id) {
                        let behind = Self.behind(fixed: model.fixedSinceNotes(info.id), noted: model.changedYourNotesSinceNotes(info.id))
                        QuietNotice(behind.text, systemImage: behind.symbol) {
                            Button("Update Notes") { model.replaceNotes(of: info.id) { model.updateNotes(info.id) } }
                        }
                    }
                    if model.suggestsDeleting(info) {
                        QuietNotice(String(localized: "All Action Items are done. Delete this Conversation?"), systemImage: "checkmark.circle", tint: .green) {
                            Button("Not now") { model.notNowForDeleting(info.id) }
                                .help("Ask again in a week")
                            Button("Delete…", role: .destructive) { confirmingDelete = true }
                        }
                    }
                    let player = SourcePlayer(playback: playback, transcript: { result.transcript.applying(model.flags[info.id] ?? TranscriptFlags()) }) { time in
                        tab = .transcript
                        playback.seek(to: time)
                        playback.play()
                    }
                    switch tab {
                    case .notes:
                        NotesView(result: result, yourNotes: model.yourNotes[info.id] ?? [], player: player) { notes in
                            model.saveNotes(notes, for: info.id)
                        } addToCalendar: { item in
                            model.addToCalendar(item, in: info.id)
                        } setDone: { index, done in
                            model.setActionItem(index, done: done, in: info.id)
                        } openTranscript: {
                            tab = .transcript
                        } changeYourNotes: { notes in
                            model.setYourNotes(notes, for: info.id)
                        }
                        // A Conversation's draft stays with it when another one is selected.
                        .id(info.id)
                    case .transcript:
                        TranscriptView(model: model, info: info, result: result, playback: playback)
                    case .speakers:
                        SpeakersView(model: model, info: info, result: result, playback: playback)
                    case .chat:
                        ChatView(model: model, info: info, turns: result.turns, player: player)
                    }
                }
            } else {
                ContentUnavailableView("The Notes file is missing", systemImage: "questionmark.folder")
            }
        }
    }

    /// Why the Notes are behind: the user's fixes to the Transcript, their notes, or both, or else separating people who
    /// talked at once.
    private static func behind(fixed: Bool, noted: Bool) -> (text: String, symbol: String) {
        switch (fixed, noted) {
        case (true, true): (String(localized: "You've fixed the Transcript and changed your notes since the Notes were written."), "pencil.circle")
        case (true, false): (String(localized: "You've fixed the Transcript since the Notes were written."), "pencil.circle")
        case (false, true): (String(localized: "You've changed your notes since the Notes were written."), "pencil")
        case (false, false): (String(localized: "Separating people who talked at once changed lines the Notes cite."), "person.2.wave.2")
        }
    }

    private func speakersTabTitle(_ result: ProcessedConversation) -> String {
        let unnamed = result.speakers.filter { if case .named = $0.naming { false } else { true } }.count
        return unnamed > 0 ? String(localized: "Speakers (\(unnamed) to name)") : String(localized: "Speakers")
    }
}

/// A line about the Conversation above its views, with what can be done about it: quieter than the colored bands these
/// were, which competed with the Notes.
private struct QuietNotice<Actions: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let actions: Actions

    init(_ text: String, systemImage: String, tint: Color = .secondary, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

extension QuietNotice where Actions == EmptyView {
    init(_ text: String, systemImage: String, tint: Color = .secondary) {
        self.init(text, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}