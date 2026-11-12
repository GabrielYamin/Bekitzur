import BekitzurDomain
import BekitzurModels
import BekitzurPipeline
import BekitzurVocabulary
import SwiftUI

/// Settings, a pane at a time, picked in the sidebar: in one long list they had grown past a screen.
struct SettingsView: View {
    @Bindable var model: AppModel
    /// The pane last shown, which Settings opens on again.
    @AppStorage("settingsPane") private var pane = SettingsPane.recording

    static let project = URL(string: "https://github.com/GabrielYamin/Bekitzur")!

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                HStack(spacing: 6) {
                    Label(pane.title, systemImage: pane.symbol)
                    if pane.holds(model.newSettingsShown) { NewBadge() }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                shown
            }
            .formStyle(.grouped)
            // A pane opens at its top, not scrolled as far as the one before it was.
            .id(pane)
        }
        .frame(minWidth: 680, minHeight: 460)
        // The first time Settings opens after an update that added settings, it opens on their pane.
        .onChange(of: model.newSettingsShown, initial: true) {
            if let new = SettingsPane.allCases.first(where: { $0.holds(model.newSettingsShown) }) { pane = new }
        }
    }

    /// The sidebar's selection, which a click on nothing leaves as it is.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { picked in if let picked { pane = picked } })
    }

    @ViewBuilder
    private var shown: some View {
        switch pane {
        case .recording: RecordingPane(model: model)
        case .language: LanguagePane(model: model)
        case .people: PeoplePane(model: model)
        case .vocabulary: VocabularyPane(model: model)
        case .models: ModelsPane(model: model)
        case .aiApps: AIAppsPane(model: model)
        case .storage: StoragePane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

/// The parts of Settings, each a pane of its own.
enum SettingsPane: String, CaseIterable, Identifiable {
    case recording, language, people, vocabulary, models, aiApps, storage, about

    var id: Self { self }

    var title: String {
        switch self {
        case .recording: String(localized: "Recording")
        case .language: String(localized: "Language")
        case .people: String(localized: "People")
        case .vocabulary: String(localized: "Vocabulary")
        case .models: String(localized: "Models")
        case .aiApps: String(localized: "AI apps")
        case .storage: String(localized: "Storage")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .language: "globe"
        case .people: "person.2"
        case .vocabulary: "character.book.closed"
        case .models: "shippingbox"
        case .aiApps: "sparkles"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }

    /// It has one of these settings.
    func holds(_ settings: Set<NewSetting>) -> Bool {
        let own: Set<NewSetting> = switch self {
        case .recording: [.microphone, .recordCallsAutomatically]
        case .language: [.appLanguage, .notesLanguage]
        case .aiApps: [.aiApps]
        case .people, .vocabulary, .models, .storage, .about: []
        }
        return !own.isDisjoint(with: settings)
    }
}

private struct RecordingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker(selection: $model.microphoneUID) {
                microphoneChoices(model)
            } label: {
                HStack(spacing: 6) {
                    Text("Microphone")
                    if model.newSettingsShown.contains(.microphone) { NewBadge() }
                }
            }
            Text("Bekitzur records the microphone picked here, or the Mac's default while it isn't connected. The other side of a call is everything the Mac plays, whatever it plays through.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Suggest recording calls", isOn: $model.suggestsCalls)
            Text("When Slack, Teams, Zoom, FaceTime, or a browser starts using the microphone, Bekitzur offers to record, and once it stops, to stop recording. A call can't be seen while it rings, so the offer comes when you answer or join.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle(isOn: $model.recordsCallsAutomatically) {
                HStack(spacing: 6) {
                    Text("Record calls automatically")
                    if model.newSettingsShown.contains(.recordCallsAutomatically) { NewBadge() }
                }
            }
            Text("Recording starts on its own when a call does, and stops once the call is over, with a notification each time. A recording you start yourself never stops on its own. Let the people on the call know they're recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Send a test notification") { model.sendTestNotification() }
                Text("Not showing? Check System Settings → Notifications → Bekitzur, and that Focus is off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Text("Bekitzur records your microphone and everything your Mac plays. On calls, use headphones so your microphone doesn't pick up the other side a second time.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("It tells Hebrew from English by the first half minute of speech. If it gets one wrong, choose Transcribe again as… in the Conversation's menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LanguagePane: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker(selection: $model.appLanguage) {
                Text("Same as the Mac").tag(AppLanguage.mac)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "עברית").tag(AppLanguage.hebrew)
            } label: {
                HStack(spacing: 6) {
                    Text("App language")
                    if model.newSettingsShown.contains(.appLanguage) { NewBadge() }
                }
            }
            if model.switchesOnRestart {
                HStack {
                    if model.canRestart {
                        Text("Bekitzur switches once it restarts.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Bekitzur switches once it restarts, after it's done recording and processing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restart Bekitzur") { model.restartInChosenLanguage() }
                        .disabled(!model.canRestart)
                }
            }
        }
        Section {
            Picker(selection: $model.notesLanguage) {
                Text(verbatim: "English").tag(ConversationLanguage.english)
                Text(verbatim: "עברית").tag(ConversationLanguage.hebrew)
            } label: {
                HStack(spacing: 6) {
                    Text("Notes language")
                    if model.newSettingsShown.contains(.notesLanguage) { NewBadge() }
                }
            }
            Text("Bekitzur writes Notes in this language, whatever language the Conversation is in. Notes it wrote before stay as they are; to write a Conversation's Notes in this language, choose Write Notes again in the Conversation's menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The user's own voice, and the people Bekitzur knows by voice, each to rename, which carries into every Conversation
/// they're in, or forget.
private struct PeoplePane: View {
    @Bindable var model: AppModel
    @ViewState private var renaming: String?
    @ViewState private var newName = ""
    @FocusState private var focused: Bool

    var body: some View {
        Section("Your voice") {
            TextField("Your name", text: $model.userName)
            voiceSample
        }
        Section {
            if model.people.isEmpty {
                Text("No one yet. Name Speakers in a Conversation and they're added here.").foregroundStyle(.secondary)
            }
            ForEach(model.people, id: \.self) { person in
                if renaming == person {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $newName)
                                .labelsHidden()
                                .multilineTextAlignment(.leading)
                                .textFieldStyle(.roundedBorder)
                                .focused($focused)
                                .onAppear { focused = true }
                                .onSubmit(save)
                                .onExitCommand { renaming = nil }
                            Button("Cancel") { renaming = nil }
                            Button("Rename", action: save)
                                .buttonStyle(.borderedProminent)
                                .disabled(trimmed.isEmpty || trimmed == person)
                        }
                        if trimmed != person, model.people.contains(trimmed) {
                            Text("\(trimmed) is already in People: they become one person, with both voices.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Text(person)
                        Spacer()
                        Button("Rename…") {
                            newName = person
                            renaming = person
                        }
                        Button("Forget", role: .destructive) { model.forget(person) }
                    }
                }
            }
        } header: {
            Text("People")
        } footer: {
            Text("Renaming someone changes their name in every Conversation they're in, too.")
        }
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard let person = renaming, !trimmed.isEmpty, trimmed != person else { return }
        model.renamePerson(person, to: trimmed)
        renaming = nil
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

/// The team's English terms and the spellings learned from corrections, which Hebrew Transcripts are checked against.
private struct VocabularyPane: View {
    let model: AppModel
    @ViewState private var newTerm = ""

    var body: some View {
        Section {
            HStack {
                // In a grouped Form the title is a label beside an empty field with no border, which reads as text
                // with an Add button that never turns on.
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
        } footer: {
            Text("When an English term is spoken in Hebrew, Bekitzur writes it in English letters. It knows \(VocabularyStore.builtInTermCount) common tech terms; add your team's own here. Typing what was said for a word in the Transcript teaches it too.")
        }
        let spellings = model.vocabulary.spellings.sorted { $0.value.lowercased() < $1.value.lowercased() }
        if !spellings.isEmpty {
            Section("Learned from your corrections") {
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
        }
    }

    private func add() {
        model.addTerm(newTerm)
        newTerm = ""
    }
}

private struct ModelsPane: View {
    let model: AppModel

    var body: some View {
        Section {
            ForEach(ModelFile.groups) { group in
                LabeledContent(ModelNames.title(group.name)) {
                    let size = group.bytes.formatted(.byteCount(style: .file))
                    let missing = group.files.contains(where: model.missingModels.contains)
                    Text(missing ? "Not downloaded, \(size)" : "Downloaded, \(size)").foregroundStyle(.secondary)
                }
            }
            ModelsNote(model: model)
            Text("Bekitzur downloads its models once, from their publishers on Hugging Face.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether AI apps may use the Conversations through Bekitzur's MCP server, and how to connect one.
private struct AIAppsPane: View {
    @Bindable var model: AppModel
    /// What adding the skill to an agent came to.
    @ViewState private var added: String? = nil

    var body: some View {
        Section {
            Toggle(isOn: $model.allowsAIApps) {
                HStack(spacing: 6) {
                    Text("Let AI apps use your Conversations")
                    if model.newSettingsShown.contains(.aiApps) { NewBadge() }
                }
            }
            Text("AI apps like Claude and Cursor can then find your Conversations, read their Notes and Transcripts, and change their Notes, through Bekitzur's MCP server. What an AI app reads goes to its model's provider, like Anthropic or OpenAI. Changes show in the Conversation's Chat tab, where you can undo them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Connect an AI app") {
                Button("Copy setup") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AIApps.setup, forType: .string)
                }
            }
            Text("Paste it into the AI app's MCP servers: ~/.cursor/mcp.json for Cursor, or Settings → Developer → Edit Config for Claude. Claude Code adds it with: claude mcp add bekitzur -- \"\(AIApps.command)\" --mcp")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Section {
            LabeledContent("Add the skill") {
                HStack {
                    ForEach(AIApps.Agent.allCases, id: \.self) { agent in
                        Button(agent.rawValue) { add(agent) }
                    }
                }
            }
            Text("When an AI app can't use MCP servers, its agent can run Bekitzur's tools from its terminal instead, and the skill tells it how.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let added {
                Text(added).font(.callout)
            }
        }
    }

    private func add(_ agent: AIApps.Agent) {
        do {
            try AIApps.addSkill(for: agent)
            added = String(localized: "Added to \(agent.rawValue), from its next chat.")
        } catch {
            added = String(localized: "Couldn't add the skill: \(error.localizedDescription)")
        }
    }
}

private struct StoragePane: View {
    let model: AppModel

    var body: some View {
        Section {
            LabeledContent("Data folder") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BekitzurPaths.conversations]) }
            }
            Text("It holds your Conversations, with their recordings, Transcripts, and Notes, your voiceprints and vocabulary, and the models. All of it stays on this Mac, unless you let AI apps use your Conversations.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Bekitzur") {
                Button("Delete Bekitzur…", role: .destructive) { model.deleteApp() }
            }
            Text("Moves the app to the Trash, with its speech models or all its data if you choose, and quits. Dragging the app to the Trash does the same.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutPane: View {
    let model: AppModel

    var body: some View {
        Section {
            LabeledContent("Version", value: model.versionDescription)
            LabeledContent("Project") {
                Link("github.com/GabrielYamin/Bekitzur", destination: SettingsView.project)
            }
            Text("Bekitzur is open source, under the MIT License. Its code, releases, and updates are on GitHub.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        Section("Disclaimer") {
            Text("Bekitzur is provided as is, without warranty of any kind, and its authors aren't liable for anything that comes of using it, like a recording that's lost or incomplete, a mistake in a Transcript, Speakers, or Notes, or a decision made from them. Everything runs on your Mac: recordings, Transcripts, Notes, and voices stay on it unless you let AI apps use your Conversations, and Bekitzur goes online only to download its models and updates. You're responsible for telling the people you record, and for following the law and your organization's rules on recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
