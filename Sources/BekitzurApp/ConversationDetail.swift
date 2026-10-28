import BekitzurDomain
import SwiftUI

struct ConversationDetail: View {
    let model: AppModel
    let info: ConversationInfo
    @ViewState private var tab = Tab.notes
    @ViewState private var playback = PlaybackModel()

    enum Tab: Hashable {
        case notes, transcript, speakers, ask
    }

    private var result: ProcessedConversation? { model.results[info.id] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = info.warning, result != nil {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(info.id)-\(info.status)") {
            model.loadResult(info.id)
            model.loadFlags(info.id)
        }
        // Reloaded when the status changes, since processing turns the recorded .aac tracks into .m4a files, and once an
        // earlier call's microphone delay is measured.
        .task(id: "\(info.id)-\(info.status)-\(info.microphoneDelay ?? -1)") {
            if info.status == .recording || info.status == .processing {
                playback.stop()
            } else {
                await playback.load(model.library.audioTracks(for: info.id), microphoneDelay: info.microphoneDelay ?? 0)
            }
        }
        .onDisappear { playback.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.displayTitle).font(.title2.bold()).textSelection(.enabled)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if result != nil {
                Button {
                    model.copyNotes(info.id)
                } label: {
                    Label("Copy Notes", systemImage: "doc.on.doc")
                }
                if info.status == .unreviewed {
                    Button("Done reviewing") { model.markReviewed(info.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Menu {
                if info.status == .reviewed {
                    Button("Mark as not reviewed") { model.markUnreviewed(info.id) }
                }
                if info.status == .unreviewed || info.status == .reviewed || info.status == .failed {
                    Button("Write Notes again") { model.writeNotesAgain(info.id) }
                    Button("Transcribe again") { model.transcribeAgain(info.id, language: info.language) }
                    let other: ConversationLanguage = info.language == .hebrew ? .english : .hebrew
                    Button("Transcribe again as \(other.name)") { model.transcribeAgain(info.id, language: other) }
                }
                Button("Show in Finder") { model.showInFinder(info.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(info.id) }
                    .disabled(info.status == .recording || info.status == .processing)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(20)
    }

    private var subtitle: String {
        var parts = [info.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())]
        if let minutes = info.minutes { parts.append("\(minutes) min") }
        parts.append(info.language.name)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch info.status {
        case .recording:
            LiveTranscriptView(model: model, info: info)
        case .processing where model.liveTranscripts[info.id] != nil:
            LiveTranscriptView(model: model, info: info)
        case .processing:
            ContentUnavailableView {
                Label(info.step ?? "Processing", systemImage: "hourglass")
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
                    if model.notesAreBehind(info.id) {
                        HStack {
                            Label("You've fixed the Transcript since the Notes were written.", systemImage: "pencil.circle")
                            Spacer()
                            Button("Update Notes") { model.updateNotes(info.id) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.yellow.opacity(0.12))
                    }
                    Picker("View", selection: $tab) {
                        Text("Notes").tag(Tab.notes)
                        Text("Transcript").tag(Tab.transcript)
                        Text(speakersTabTitle(result)).tag(Tab.speakers)
                        Text("Ask").tag(Tab.ask)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 520)
                    .padding(.vertical, 10)
                    switch tab {
                    case .notes:
                        NotesView(result: result) { time in
                            tab = .transcript
                            playback.seek(to: time)
                            playback.play()
                        }
                    case .transcript:
                        TranscriptView(model: model, info: info, result: result, playback: playback)
                        PlayerBar(playback: playback)
                    case .speakers:
                        SpeakersView(model: model, info: info, result: result)
                    case .ask:
                        AskView(model: model, info: info) { time in
                            tab = .transcript
                            playback.seek(to: time)
                            playback.play()
                        }
                    }
                }
            } else {
                ContentUnavailableView("The Notes file is missing", systemImage: "questionmark.folder")
            }
        }
    }

    private func speakersTabTitle(_ result: ProcessedConversation) -> String {
        let unnamed = result.speakers.filter { if case .named = $0.naming { false } else { true } }.count
        return unnamed > 0 ? "Speakers (\(unnamed) to name)" : "Speakers"
    }
}

/// Play and pause (space bar), where playback is, and how fast. Shown with the Transcript, which has no text fields
/// for the space bar to collide with.
private struct PlayerBar: View {
    let playback: PlaybackModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play or pause (space bar)")
            Text("\(timestamp(playback.time)) / \(timestamp(playback.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 0.1))
            Picker("Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Text("\(rate.formatted())×").tag(rate)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!playback.isLoaded)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension ConversationLanguage {
    var name: String {
        switch self {
        case .hebrew: "Hebrew"
        case .english: "English"
        }
    }
}
