import BekitzurDomain
import SwiftUI

struct NotesView: View {
    let result: ProcessedConversation
    /// What the user wrote while recording, shown beside what it's about.
    let yourNotes: [UserNote]
    /// Plays a Source where it's shown.
    let player: SourcePlayer
    /// Saves the user's changes to the Notes.
    let save: (Notes) -> Void
    /// Opens an Action Item with a due day in the calendar app.
    let addToCalendar: (ActionItem) -> Void
    /// Checks the Action Item at an index off, or back on.
    let setDone: (Int, Bool) -> Void
    /// The Notes being changed while `editing`. It's never nil: the editor's fields still read it once more as editing
    /// ends, and an optional one set to nil on Save or Cancel would crash the app as SwiftUI unwraps it.
    @ViewState private var draft = NotesDraft(Notes())
    @ViewState private var editing = false

    private var notes: Notes { result.notes }
    private var turns: [String: Turn] { Dictionary(result.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    /// What the Notes say goes in the direction of their language, inside the app's own: the section titles and
    /// buttons stay in the app's.
    private var direction: LayoutDirection { notes.language == .hebrew ? .rightToLeft : .leftToRight }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if result.notesEdited == true, !editing {
                    Label("You've edited these Notes", systemImage: "pencil").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !editing {
                    Button {
                        draft = NotesDraft(notes)
                        editing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Change the Notes: the title, summary, and each item")
                } else {
                    Button("Cancel") { editing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        save(draft.applied(to: notes))
                        editing = false
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Save the changes (⌘S)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            if editing {
                ScrollView {
                    NotesEditor(draft: $draft, direction: direction, owners: result.ownerChoices)
                        .padding(24)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            } else {
                notesView
            }
        }
    }

    private var notesView: some View {
        let margins = Margins(yourNotes, notes: notes, turns: result.turns)
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                WithMargin(margin: margins.beside(.summary), player: player) {
                    Text(notes.summary)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.layoutDirection, direction)

                if !notes.decisions.isEmpty {
                    NotesSection(title: "Decisions", direction: direction) {
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { index, decision in
                            NoteItem(
                                text: decision.text,
                                quote: decision.quote,
                                sources: decision.sourceTurns,
                                turns: turns,
                                player: player,
                                first: index == 0,
                                margin: margins.beside(.decision(index)),
                                fromYourNote: decision.fromYourNote != nil
                            )
                        }
                    }
                }

                if !notes.actionItems.isEmpty {
                    let done = notes.actionItems.filter { $0.done == true }.count
                    let detail = done > 0 ? String(localized: "\(done) of \(notes.actionItems.count) done") : nil
                    NotesSection(title: "Action Items", detail: detail, direction: direction) {
                        ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { index, item in
                            NoteItem(
                                text: item.text,
                                quote: item.quote,
                                sources: item.sourceTurns,
                                turns: turns,
                                player: player,
                                first: index == 0,
                                margin: margins.beside(.actionItem(index)),
                                fromYourNote: item.fromYourNote != nil,
                                done: Binding(get: { item.done == true }, set: { setDone(index, $0) })
                            ) {
                                HStack(spacing: 14) {
                                    OwnerToken(owner: item.owner)
                                    if let due = NotesMarkdown.dueText(item) {
                                        let said = item.duePhrase.map { String(localized: "Said: \"\($0)\"") }
                                        if item.dueDate != nil {
                                            DueChip(text: due, help: [String(localized: "Add to Calendar"), said].compactMap(\.self).joined(separator: ". ")) {
                                                addToCalendar(item)
                                            }
                                        } else {
                                            Label(due, systemImage: "calendar")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .help(said ?? "")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !notes.openQuestions.isEmpty {
                    NotesSection(title: "Open Questions", direction: direction) {
                        ForEach(Array(notes.openQuestions.enumerated()), id: \.offset) { index, question in
                            NoteItem(
                                text: question.text,
                                quote: nil,
                                sources: question.sourceTurns,
                                turns: turns,
                                player: player,
                                first: index == 0,
                                margin: margins.beside(.openQuestion(index)),
                                fromYourNote: question.fromYourNote != nil
                            )
                        }
                    }
                }

                if notes.decisions.isEmpty && notes.actionItems.isEmpty && notes.openQuestions.isEmpty {
                    Text("No Decisions, Action Items, or Open Questions in this Conversation.").foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: margins.isShown ? 780 + MarginColumn.width + MarginColumn.spacing : 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The user's notes, each beside the part of the Notes it's about, with the turn being said when they wrote it.
private struct Margins {
    let isShown: Bool
    private let entries: [UserNotePlace: [MarginNote.Entry]]

    init(_ yourNotes: [UserNote], notes: Notes, turns: [Turn]) {
        let written = yourNotes.filter { !$0.words.isEmpty }
        let places = UserNote.places(of: written, in: notes, turns: turns)
        var entries: [UserNotePlace: [MarginNote.Entry]] = [:]
        for note in written {
            guard let place = places[note.id] else { continue }
            let heard = turns.last { ($0.start ?? .infinity) <= note.at }
            entries[place, default: []].append(MarginNote.Entry(note: note, heard: heard))
        }
        isShown = !written.isEmpty
        self.entries = entries
    }

    /// Nil for a Conversation without notes of the user's, so the Notes take the whole width.
    func beside(_ place: UserNotePlace) -> [MarginNote.Entry]? {
        isShown ? entries[place] ?? [] : nil
    }
}

private enum MarginColumn {
    static let width: CGFloat = 176
    static let spacing: CGFloat = 26
}

/// What the Notes say, with the user's notes about it in a column beside it, when the Conversation has any.
private struct WithMargin<Content: View>: View {
    let margin: [MarginNote.Entry]?
    let player: SourcePlayer
    let content: Content

    init(margin: [MarginNote.Entry]?, player: SourcePlayer, @ViewBuilder content: () -> Content) {
        self.margin = margin
        self.player = player
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MarginColumn.spacing) {
            content
            if let margin {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(margin) { MarginNote(entry: $0, player: player) }
                }
                .frame(width: MarginColumn.width, alignment: .leading)
            }
        }
    }
}

/// One of the user's notes beside what it's about, with when they wrote it; it plays what was being said then.
private struct MarginNote: View {
    struct Entry: Identifiable {
        let note: UserNote
        /// The turn being said when it was written.
        let heard: Turn?
        var id: UUID { note.id }
    }

    let entry: Entry
    let player: SourcePlayer

    var body: some View {
        if let turn = entry.heard {
            SourceButton(speaker: turn.speaker, text: turn.text, player: player) {
                SourceClip(quote: nil, speaker: turn.speaker, start: turn.start, end: turn.end, in: player.transcript())
            } label: {
                label
            }
            .help("Listen to what was being said when you wrote this")
        } else {
            label
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(timestamp(entry.note.at), systemImage: "pencil")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tint)
            DirectionalText(entry.note.words)
                .font(.system(size: 12.5, weight: entry.note.kind == .heading ? .semibold : .regular))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Rectangle().fill(.tint).frame(width: 2)
        }
        .contentShape(Rectangle())
    }
}

/// Notes being edited, each item with an identity of its own so removing one doesn't move another's text.
private struct NotesDraft {
    var title: String
    var summary: String
    var decisions: [Editable<Decision>]
    var actionItems: [Editable<ActionItem>]
    var openQuestions: [Editable<OpenQuestion>]

    init(_ notes: Notes) {
        title = notes.title
        summary = notes.summary
        decisions = notes.decisions.map { Editable(item: $0) }
        actionItems = notes.actionItems.map { Editable(item: $0) }
        openQuestions = notes.openQuestions.map { Editable(item: $0) }
    }

    /// `notes` with the changes, without the items left empty; an empty title keeps the old one.
    func applied(to notes: Notes) -> Notes {
        var notes = notes
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { notes.title = title }
        notes.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        notes.decisions = decisions.map(\.item).compactMap { decision in
            var decision = decision
            decision.text = decision.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return decision.text.isEmpty ? nil : decision
        }
        notes.actionItems = actionItems.map(\.item).compactMap { item in
            var item = item
            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            item.owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.owner?.isEmpty == true { item.owner = nil }
            return item.text.isEmpty ? nil : item
        }
        notes.openQuestions = openQuestions.map(\.item).compactMap { question in
            var question = question
            question.text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return question.text.isEmpty ? nil : question
        }
        return notes
    }
}

private struct Editable<Item>: Identifiable {
    let id = UUID()
    var item: Item
}

private struct NotesEditor: View {
    @Binding var draft: NotesDraft
    /// The Notes' language's, for what they say.
    let direction: LayoutDirection
    /// Who Action Items can be for, from the Notes as saved, so a name half typed in one isn't offered in the others.
    let owners: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Title").font(.headline)
                TextField("Title", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .environment(\.layoutDirection, direction)
                Text("Summary").font(.headline).padding(.top, 8)
                TextField("Summary", text: $draft.summary, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...)
                    .environment(\.layoutDirection, direction)
            }

            EditedSection(title: "Decisions", systemImage: "checkmark.seal", add: "Add a Decision", direction: direction) {
                draft.decisions.append(Editable(item: Decision(text: "")))
            } content: {
                ForEach($draft.decisions) { $decision in
                    EditedItem(text: $decision.item.text, placeholder: "What was decided") {
                        draft.decisions.removeAll { $0.id == decision.id }
                    }
                }
            }

            EditedSection(title: "Action Items", systemImage: "checklist", add: "Add an Action Item", direction: direction) {
                draft.actionItems.append(Editable(item: ActionItem(text: "")))
            } content: {
                ForEach($draft.actionItems) { $item in
                    EditedItem(text: $item.item.text, placeholder: "What to do") {
                        draft.actionItems.removeAll { $0.id == item.id }
                    } details: {
                        ActionItemDetails(item: $item.item, owners: owners)
                    }
                }
            }

            EditedSection(title: "Open Questions", systemImage: "questionmark.bubble", add: "Add an Open Question", direction: direction) {
                draft.openQuestions.append(Editable(item: OpenQuestion(text: "")))
            } content: {
                ForEach($draft.openQuestions) { $question in
                    EditedItem(text: $question.item.text, placeholder: "What's still open") {
                        draft.openQuestions.removeAll { $0.id == question.id }
                    }
                }
            }
        }
    }
}

private struct EditedSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let add: LocalizedStringKey
    /// The items', which can be the other way from the title's.
    let direction: LayoutDirection
    let onAdd: () -> Void
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringKey,
        systemImage: String,
        add: LocalizedStringKey,
        direction: LayoutDirection,
        onAdd: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.add = add
        self.direction = direction
        self.onAdd = onAdd
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.title3.bold())
            content.environment(\.layoutDirection, direction)
            Button(action: onAdd) {
                Label(add, systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct EditedItem<Details: View>: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    let remove: () -> Void
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            details
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension EditedItem where Details == EmptyView {
    init(text: Binding<String>, placeholder: LocalizedStringKey, remove: @escaping () -> Void) {
        self.init(text: text, placeholder: placeholder, remove: remove) { EmptyView() }
    }
}

/// An Action Item's Owner and due date, with its time of day if it has one. A due date that was said but not resolved to
/// a day ("after the release") shows as it was said until a day is picked.
private struct ActionItemDetails: View {
    @Binding var item: ActionItem
    /// Who it can be for, which the Owner field lists while it's edited.
    let owners: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person").foregroundStyle(.secondary)
            TextField("No Owner", text: Binding(get: { item.owner.map(ShownNames.speaker) ?? "" }, set: { item.owner = $0 }))
                // A Speaker without a name is picked by its label, which naming it later changes in the Owner too.
                .textInputSuggestions {
                    ForEach(suggestedOwners, id: \.self) { owner in
                        Label(ShownNames.speaker(owner), systemImage: "person").textInputCompletion(owner)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Image(systemName: "calendar").foregroundStyle(.secondary).padding(.leading, 6)
            if let day = item.dueDate.flatMap(Self.day.date(from:)) {
                DatePicker("Due", selection: Binding(get: { day }, set: { item.setDue(day: Self.day.string(from: $0)) }), displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
                if let time = item.dueTimeOfDay {
                    DatePicker("Time", selection: Binding(get: { Self.moment(time) }, set: { item.setDue(time: Self.time(of: $0)) }), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    Button {
                        item.setDue(time: nil)
                    } label: {
                        Image(systemName: "clock.badge.xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("No time")
                } else {
                    Button("Add a time") { item.setDue(time: DueTime(hour: 9, minute: 0)) }
                        .buttonStyle(.borderless)
                }
                removeDue
            } else if let phrase = item.duePhrase {
                Text("“\(phrase)”").foregroundStyle(.secondary)
                Button("Pick a day") { item.dueDate = Self.day.string(from: Date()) }
                    .buttonStyle(.borderless)
                removeDue
            } else {
                Button("Add a due date") { item.dueDate = Self.day.string(from: Date()) }
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
    }

    /// The Owners to pick from for what's typed: all of them until it narrows them down, so one already picked can be
    /// swapped for another.
    private var suggestedOwners: [String] {
        let typed = (item.owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !owners.contains(typed) else { return owners }
        return owners.filter { ShownNames.speaker($0).localizedStandardContains(typed) }
    }

    private var removeDue: some View {
        Button {
            item.dueDate = nil
            item.dueTime = nil
            item.duePhrase = nil
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("No due date")
    }

    /// A time of day as the time picker shows it, on any day.
    private static func moment(_ time: DueTime) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    private static func time(of moment: Date) -> DueTime {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: moment)
        return DueTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
    }

    /// Days as Action Items keep them, YYYY-MM-DD.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// A part of the Notes under a small title, its items one after another like lines in a document.
private struct NotesSection<Content: View>: View {
    let title: LocalizedStringKey
    /// Beside the title, like how many Action Items are done.
    var detail: String?
    /// The items', which can be the other way from the title's.
    let direction: LayoutDirection
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, detail: String? = nil, direction: LayoutDirection, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.direction = direction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            content.environment(\.layoutDirection, direction)
        }
    }
}

private struct NoteItem<Details: View>: View {
    let text: String
    let quote: String?
    let sources: [String]
    let turns: [String: Turn]
    let player: SourcePlayer
    /// The section's first item, with no hairline above it.
    let first: Bool
    /// The user's notes about it; nil for a Conversation without any.
    let margin: [MarginNote.Entry]?
    /// Whether the Notes have it only because of a note of the user's.
    let fromYourNote: Bool
    /// An Action Item's check box; nil for a Decision or an Open Question.
    var done: Binding<Bool>?
    @ViewBuilder let details: Details

    init(
        text: String,
        quote: String?,
        sources: [String],
        turns: [String: Turn],
        player: SourcePlayer,
        first: Bool,
        margin: [MarginNote.Entry]? = nil,
        fromYourNote: Bool = false,
        done: Binding<Bool>? = nil,
        @ViewBuilder details: () -> Details
    ) {
        self.text = text
        self.quote = quote
        self.sources = sources
        self.turns = turns
        self.player = player
        self.first = first
        self.margin = margin
        self.fromYourNote = fromYourNote
        self.done = done
        self.details = details()
    }

    var body: some View {
        WithMargin(margin: margin, player: player) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let done {
                    Button {
                        done.wrappedValue.toggle()
                    } label: {
                        Image(systemName: done.wrappedValue ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(done.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(done.wrappedValue ? "Mark as not done" : "Mark as done")
                }
                content.opacity(done?.wrappedValue == true ? 0.6 : 1)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first { Divider() }
        }
    }

    /// The item, then on one line its Owner and due day and its Sources; the quote it stands on shows in a Source's
    /// popover, which plays it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text)
                .font(.system(size: 14, weight: done == nil ? .regular : .medium))
                .strikethrough(done?.wrappedValue == true)
            HStack(spacing: 14) {
                details
                if fromYourNote {
                    Label("From your note", systemImage: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Bekitzur added this for a note you wrote while recording")
                }
                sourceButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each Source's time, with who said it only where that changes, so three of one person's lines read as one name.
    private var sourceButtons: some View {
        let shown = sources.compactMap { turns[$0] }
        return HStack(spacing: 10) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, turn in
                let named = index == 0 || shown[index - 1].speaker != turn.speaker
                SourceButton(speaker: turn.speaker, text: turn.text, player: player) {
                    SourceClip(quote: quote, speaker: turn.speaker, start: turn.start, end: turn.end, in: player.transcript())
                } label: {
                    Label {
                        Text(verbatim: named ? "\(ShownNames.speaker(turn.speaker)) \(timestamp(turn.start))" : timestamp(turn.start))
                    } icon: {
                        Image(systemName: "play.fill").imageScale(.small)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .help("Listen: \(turn.text)")
            }
        }
    }
}

extension NoteItem where Details == EmptyView {
    init(
        text: String,
        quote: String?,
        sources: [String],
        turns: [String: Turn],
        player: SourcePlayer,
        first: Bool,
        margin: [MarginNote.Entry]? = nil,
        fromYourNote: Bool = false
    ) {
        self.init(text: text, quote: quote, sources: sources, turns: turns, player: player, first: first, margin: margin, fromYourNote: fromYourNote) {
            EmptyView()
        }
    }
}

/// An Action Item's Owner with their avatar, or No Owner.
private struct OwnerToken: View {
    let owner: String?

    var body: some View {
        if let owner {
            HStack(spacing: 5) {
                PersonAvatar(name: owner, size: 16)
                Text(ShownNames.speaker(owner))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Label("No Owner", systemImage: "person")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A due day that adds its Action Item to the calendar, with a + after the day, lit under the pointer.
private struct DueChip: View {
    let text: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label {
                HStack(spacing: 5) {
                    Text(text)
                    Image(systemName: "plus").font(.caption.bold())
                }
            } icon: {
                Image(systemName: "calendar")
            }
            .font(.callout)
            .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(hovering ? 0.12 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
