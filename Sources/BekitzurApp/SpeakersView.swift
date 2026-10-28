import BekitzurDomain
import SwiftUI

struct SpeakersView: View {
    let model: AppModel
    let info: ConversationInfo
    let result: ProcessedConversation
    @ViewState private var people: Int?

    var body: some View {
        List {
            Section {
                ForEach(result.speakers, id: \.label) { speaker in
                    SpeakerRow(
                        model: model,
                        id: info.id,
                        speaker: speaker,
                        said: result.turns.filter { $0.speaker == speaker.displayName }.prefix(3).map(\.text)
                    )
                }
            } footer: {
                Text("Bekitzur remembers the names you give and recognizes those voices in later Conversations. Giving two Speakers the same name joins them.")
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
}

private struct SpeakerRow: View {
    let model: AppModel
    let id: String
    let speaker: ConversationSpeaker
    let said: [String]
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
            ForEach(Array(said.enumerated()), id: \.offset) { _, line in
                DirectionalText(line).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
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
