import BekitzurDomain
import SwiftUI

struct SpeakersView: View {
    let model: AppModel
    let info: ConversationInfo
    let result: ProcessedConversation
    let playback: PlaybackModel
    @ViewState private var people: Int?

    var body: some View {
        List {
            Section {
                ForEach(result.speakers, id: \.label) { speaker in
                    SpeakerRow(
                        model: model,
                        id: info.id,
                        speaker: speaker,
                        said: Self.samples(of: speaker.displayName, in: result.turns),
                        playback: playback
                    )
                }
            } footer: {
                Text("Bekitzur remembers the names you give and recognizes those voices in later Conversations. Giving two Speakers the same name joins them. Play a line to hear who said it.")
            }

            Section {
                HStack {
                    Picker("People who spoke", selection: $people) {
                        ForEach(AppModel.peopleChoices, id: \.self) { choice in
                            Text(AppModel.peopleTitle(choice)).tag(choice)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Separate Speakers again") { model.separateSpeakersAgain(info.id, people: people) }
                        .disabled(people == info.people)
                }
            } footer: {
                Text("If Bekitzur found the wrong number of people, say how many spoke. Speakers and Notes are made again; the Transcript stays. Names you gave are kept only for voices Bekitzur recognizes.")
            }
        }
        .onAppear { people = info.people }
    }

    /// Up to three things the Speaker said, to tell who it is by reading and listening: the first that last two seconds
    /// or more, since a "yes" says little about who spoke, or the first three when nothing they said is that long.
    private static func samples(of speaker: String, in turns: [Turn]) -> [Turn] {
        let theirs = turns.filter { $0.speaker == speaker }
        let long = theirs.filter { turn in
            guard let start = turn.start, let end = turn.end else { return false }
            return end - start >= 2
        }
        return Array((long.isEmpty ? theirs : long).prefix(3))
    }
}

private struct SpeakerRow: View {
    let model: AppModel
    let id: String
    let speaker: ConversationSpeaker
    let said: [Turn]
    let playback: PlaybackModel
    @ViewState private var name = ""
    @ViewState private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(speaker.displayName).font(.headline)
                Text(Duration.seconds(speaker.speechSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                    .foregroundStyle(.secondary)
                Spacer()
                switch speaker.naming {
                case .named(_, let similarity):
                    if similarity < 1 { Text("Recognized by voice").foregroundStyle(.secondary) }
                    if !renaming { Button("Not right? Rename") { renaming = true } }
                case .suggested(let suggestion, _):
                    Text("Is this \(suggestion)?")
                    Button("Yes") { model.nameSpeaker(speaker.label, as: suggestion, in: id) }
                    Button("No") { model.rejectSuggestion(speaker.label, in: id) }
                case .unknown:
                    nameField
                }
            }
            if renaming { HStack { Spacer(); nameField } }
            ForEach(Array(said.enumerated()), id: \.offset) { _, turn in
                let rightToLeft = turn.text.isMostlyRightToLeft
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let start = turn.start {
                        listenButton(from: start, to: turn.end)
                    }
                    DirectionalText(turn.text, rightToLeft: rightToLeft).foregroundStyle(.secondary).lineLimit(2)
                }
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            }
        }
        .padding(.vertical, 6)
    }

    /// Plays the line, or its first 15 seconds when it's long, which is enough to know the voice.
    private func listenButton(from start: Double, to end: Double?) -> some View {
        let playing = playback.isPlaying && playback.clip?.lowerBound == start
        return Button {
            if playing {
                playback.pause()
            } else {
                playback.play(start...max(start + 0.5, min(end ?? start + 15, start + 15)))
            }
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(!playback.isLoaded)
        .help(playing ? "Stop" : "Listen")
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            TextField("Who is this?", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(save)
            if !model.people.isEmpty {
                Menu("People") {
                    ForEach(model.people, id: \.self) { person in
                        Button(person) { name = person; save() }
                    }
                }
                .fixedSize()
            }
            Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.nameSpeaker(speaker.label, as: name, in: id)
        name = ""
        renaming = false
    }
}
