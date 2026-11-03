import BekitzurDomain
import BekitzurModels
import BekitzurPipeline
import BekitzurVocabulary
import SwiftUI

/// The team's English terms and the spellings learned from corrections, which Hebrew Transcripts are checked against.
private struct VocabularySection: View {
    let model: AppModel
    @ViewState private var newTerm = ""

    var body: some View {
        Section {
            HStack {
                // In a grouped Form the title is a label beside an empty field with no border, which read as text
                // with an Add button that never turned on.
                TextField("New term", text: $newTerm, prompt: Text("Add a term, like your product's name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(model.vocabulary.terms, id: \.self) { term in
                HStack {
                    Text(term)
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTerm(term) }
                }
            }
            let spellings = model.vocabulary.spellings.sorted { $0.value.lowercased() < $1.value.lowercased() }
            if !spellings.isEmpty {
                Text("Learned from your corrections").font(.subheadline).foregroundStyle(.secondary)
                ForEach(spellings, id: \.key) { spelling, term in
                    HStack {
                        Text(spelling).environment(\.layoutDirection, .rightToLeft)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(term)
                        Spacer()
                        Button("Forget", role: .destructive) { model.forgetSpelling(spelling) }
                    }
                }
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("When an English term is spoken in Hebrew, Bekitzur writes it in English letters. It knows \(VocabularyStore.builtInTermCount) common tech terms; add your team's own here. Typing what was said for a word in the Transcript teaches it too.")
        }
    }

    private func add() {
        model.addTerm(newTerm)
        newTerm = ""
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Suggest recording calls", isOn: $model.suggestsCalls)
                Text("When Slack, Teams, Zoom, FaceTime, or a browser starts using the microphone, Bekitzur offers to record, and once it stops, to stop recording. A call can't be seen while it rings, so the offer comes when you answer or join.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Record calls automatically", isOn: $model.recordsCallsAutomatically)
                Text("Recording starts on its own when a call does, and stops once the call is over, with a notification each time. A recording you start yourself never stops on its own. Let the people on the call know they're recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Send a test notification") { model.sendTestNotification() }
                    Text("Not showing? Check System Settings → Notifications → Bekitzur, and that Focus is off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Bekitzur records your microphone and everything your Mac plays. On calls, use headphones so your microphone doesn't pick up the other side a second time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("It tells Hebrew from English by the first half minute of speech. If it gets one wrong, choose Transcribe again as… in the Conversation's menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Your voice") {
                TextField("Your name", text: $model.userName)
                voiceSample
            }

            Section("People") {
                if model.people.isEmpty {
                    Text("No one yet. Name Speakers in a Conversation and they're added here.").foregroundStyle(.secondary)
                }
                ForEach(model.people, id: \.self) { person in
                    HStack {
                        Text(person)
                        Spacer()
                        Button("Forget", role: .destructive) { model.forget(person) }
                    }
                }
            }

            VocabularySection(model: model)

            Section("Models") {
                ForEach(ModelFile.all) { file in
                    LabeledContent(file.name) {
                        let size = file.bytes.formatted(.byteCount(style: .file))
                        Text(model.missingModels.contains(file) ? "Not downloaded, \(size)" : "Downloaded, \(size)").foregroundStyle(.secondary)
                    }
                }
                ModelsNote(model: model)
                Text("Bekitzur downloads its models once, from their publishers on Hugging Face.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Conversations") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BekitzurPaths.conversations]) }
                }
                Text("Recordings, Transcripts, Notes, and voices stay on this Mac.").font(.callout).foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Version", value: model.versionDescription)
                if model.canUpdate {
                    HStack {
                        Button("Check for Updates…") { Task { await model.checkForUpdates(manually: true) } }
                            .disabled(model.updateStep != nil)
                        if let step = model.updateStep {
                            ProgressView().controlSize(.small)
                            Text(step).foregroundStyle(.secondary)
                        }
                    }
                    Text("Bekitzur checks for a new version when it opens and every few hours, and asks before installing it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var voiceSample: some View {
        switch model.voiceSample {
        case .idle, .failed, .learned:
            if case .learned(let name) = model.voiceSample {
                Label("Bekitzur now recognizes \(name)'s voice.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if case .failed(let message) = model.voiceSample {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Text("Read the paragraph below aloud for 30 seconds so Bekitzur knows your voice.")
                Spacer()
                Button(model.people.contains(model.userName) ? "Record again" : "Record voice sample") {
                    Task { await model.recordVoiceSample() }
                }
                .disabled(model.userName.trimmingCharacters(in: .whitespaces).isEmpty || model.isRecording)
            }
            readingText
        case .recording(let until):
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Recording, keep reading…")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))) s").monospacedDigit()
                }
            }
            readingText
        case .learning:
            HStack {
                ProgressView().controlSize(.small)
                Text("Learning your voice…")
            }
        }
    }

    private var readingText: some View {
        DirectionalText(
            "שלום, קוראים לי \(model.userName). רוב היום שלי עובר בין code reviews, פגישות תכנון ותקלות ב-production. בבוקר אני בדרך כלל עובר על ה-dashboards ובודק שה-pipeline ירוק, ואחר כך מתחיל לעבוד על המשימות של הספרינט. כשמשהו נשבר, אני קודם כל מסתכל בלוגים ורק אז פותח טיקט. אני אוהב לסגור דברים מהר, אבל משתדל לא לשבור את ה-staging. בסוף השבוע אני מנסה לא לפתוח את המחשב בכלל, ובדרך כלל זה אפילו מצליח לי."
        )
        .font(.callout)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}
