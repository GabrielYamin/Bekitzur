import BekitzurDomain
import SwiftUI

struct NotesView: View {
    let result: ProcessedConversation
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
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            if editing {
                ScrollView {
                    NotesEditor(draft: $draft, direction: direction)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(notes.summary)
                    .font(.body)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, direction)

                if !notes.decisions.isEmpty {
                    NotesSection(title: "Decisions", systemImage: "checkmark.seal", direction: direction) {
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, decision in
                            NoteItem(text: decision.text, quote: decision.quote, sources: decision.sourceTurns, turns: turns, player: player)
                        }
                    }
                }

                if !notes.actionItems.isEmpty {
                    let done = notes.actionItems.filter { $0.done == true }.count
                    let detail = done > 0 ? String(localized: "\(done) of \(notes.actionItems.count) done") : nil
                    NotesSection(title: "Action Items", systemImage: "checklist", detail: detail, direction: direction) {
                        ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { index, item in
                            NoteItem(
                                text: item.text,
                                quote: item.quote,
                                sources: item.sourceTurns,
                                turns: turns,
                                player: player,
                                done: Binding(get: { item.done == true }, set: { setDone(index, $0) })
                            ) {
                                HStack(spacing: 6) {
                                    Chip(item.owner.map(ShownNames.speaker) ?? String(localized: "No Owner"), systemImage: "person", prominent: item.owner != nil)
                                    if let due = NotesMarkdown.dueText(item) {
                                        let said = item.duePhrase.map { String(localized: "Said: \"\($0)\"") }
                                        if item.dueDate != nil {
                                            DueChip(text: due, help: [String(localized: "Add to Calendar"), said].compactMap(\.self).joined(separator: ". ")) {
                                                addToCalendar(item)
                                            }
                                        } else {
                                            Chip(due, systemImage: "calendar", prominent: true)
                                                .help(said ?? "")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !notes.openQuestions.isEmpty {
                    NotesSection(title: "Open Questions", systemImage: "questionmark.bubble", direction: direction) {
                        ForEach(Array(notes.openQuestions.enumerated()), id: \.offset) { _, question in
                            NoteItem(text: question.text, quote: nil, sources: question.sourceTurns, turns: turns, player: player)
                        }
                    }
                }

                if notes.decisions.isEmpty && notes.actionItems.isEmpty && notes.openQuestions.isEmpty {
                    Text("No Decisions, Action Items, or Open Questions in this Conversation.").foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
                        ActionItemDetails(item: $item.item)
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person").foregroundStyle(.secondary)
            TextField("No Owner", text: Binding(get: { item.owner.map(ShownNames.speaker) ?? "" }, set: { item.owner = $0 }))
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

private struct NotesSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// Beside the title, like how many Action Items are done.
    var detail: String?
    /// The items', which can be the other way from the title's.
    let direction: LayoutDirection
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, systemImage: String, detail: String? = nil, direction: LayoutDirection, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.direction = direction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(title, systemImage: systemImage).font(.title3.bold())
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
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
    /// An Action Item's check box; nil for a Decision or an Open Question.
    var done: Binding<Bool>?
    @ViewBuilder let details: Details

    init(
        text: String,
        quote: String?,
        sources: [String],
        turns: [String: Turn],
        player: SourcePlayer,
        done: Binding<Bool>? = nil,
        @ViewBuilder details: () -> Details
    ) {
        self.text = text
        self.quote = quote
        self.sources = sources
        self.turns = turns
        self.player = player
        self.done = done
        self.details = details()
    }

    var body: some View {
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).fontWeight(.medium).strikethrough(done?.wrappedValue == true)
            details
            if let quote, !quote.isEmpty {
                DirectionalText("“\(quote)”").font(.callout).foregroundStyle(.secondary)
            }
            if !sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sources, id: \.self) { id in
                        if let turn = turns[id] {
                            SourceButton(speaker: turn.speaker, text: turn.text, player: player) {
                                SourceClip(quote: quote, speaker: turn.speaker, start: turn.start, end: turn.end, in: player.transcript())
                            } label: {
                                Label("\(ShownNames.speaker(turn.speaker)) \(timestamp(turn.start))", systemImage: "play.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                            .help("Listen: \(turn.text)")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NoteItem where Details == EmptyView {
    init(text: String, quote: String?, sources: [String], turns: [String: Turn], player: SourcePlayer) {
        self.init(text: text, quote: quote, sources: sources, turns: turns, player: player) { EmptyView() }
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String
    let prominent: Bool

    init(_ text: String, systemImage: String, prominent: Bool) {
        self.text = text
        self.systemImage = systemImage
        self.prominent = prominent
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(prominent ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(prominent ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
    }
}

/// A due day that adds its Action Item to the calendar: the due Chip with a + after the day, lit under the pointer.
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
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(hovering ? 0.28 : 0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
