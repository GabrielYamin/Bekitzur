import BekitzurDomain
import SwiftUI

/// The user's own notes while recording: a line each, with the moment it was started beside it. Return starts a new
/// line, and Delete on an empty one takes off its "#" or "[ ]", then removes it. Once the Notes are being written, the
/// notes only show.
struct YourNotesEditor: View {
    let model: AppModel
    let info: ConversationInfo
    @FocusState private var focused: UUID?
    /// The line the keyboard moves to, whose caret goes at its end: focused, a field selects all of its text.
    @ViewState private var caretAtEnd: UUID?

    static let gutter: CGFloat = 52

    var body: some View {
        let editable = model.takesYourNotes(info)
        let fallback: TextDirection = info.language == .hebrew ? .rightToLeft : .leftToRight
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your notes")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(editable ? "Each line keeps the moment you wrote it. Bekitzur reads them when it writes the Notes." : "Bekitzur is reading these alongside the Transcript.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, Self.gutter)
                .padding(.bottom, 4)
                ForEach(editable ? notes : notes.filter { !$0.words.isEmpty }) { note in
                    YourNoteLine(
                        note: note,
                        content: content(of: note.id),
                        editable: editable,
                        prompt: notes.count == 1 && note.words.isEmpty,
                        writing: focused == note.id,
                        rightToLeft: note.content.direction(fallback: fallback) == .rightToLeft,
                        focused: $focused,
                        caretAtEnd: $caretAtEnd,
                        onReturn: { newLine(after: note.id) },
                        onDeleteEmpty: { deleteEmpty(note.id) },
                        onMove: { move(from: note.id, by: $0) }
                    )
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 24, trailing: 30))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: info.id) {
            model.loadYourNotes(info.id)
            guard model.takesYourNotes(info) else { return }
            if notes.isEmpty {
                model.setYourNotes([UserNote(at: elapsed(), text: "")], for: info.id)
            }
            focus(notes.last?.id)
        }
    }

    private var notes: [UserNote] {
        model.yourNotes[info.id] ?? []
    }

    /// A line's text after its "#" or "[ ]"; its moment is when it gets its first word.
    private func content(of id: UUID) -> Binding<String> {
        Binding(
            get: { notes.first { $0.id == id }?.content ?? "" },
            set: { typed in
                change(id) { note in
                    let started = note.words.isEmpty
                    note.setContent(typed)
                    if started, !note.words.isEmpty { note.at = elapsed() }
                }
            }
        )
    }

    private func change(_ id: UUID, _ edit: (inout UserNote) -> Void) {
        var changed = notes
        guard let index = changed.firstIndex(where: { $0.id == id }) else { return }
        edit(&changed[index])
        model.setYourNotes(changed, for: info.id)
    }

    /// Seconds into the recording; once it stopped, its end.
    private func elapsed() -> Double {
        let now = Date().timeIntervalSince(info.startedAt)
        return info.endedAt.map { min(now, $0.timeIntervalSince(info.startedAt)) } ?? now
    }

    /// Return on an empty heading or task makes it a plain line, as in a checklist; otherwise a new line follows, a task
    /// after a task.
    private func newLine(after id: UUID) {
        var changed = notes
        guard let index = changed.firstIndex(where: { $0.id == id }) else { return }
        let note = changed[index]
        if note.kind != .point, note.words.isEmpty {
            changed[index].text = ""
        } else {
            let next = UserNote(at: elapsed(), text: note.kind == .task ? "[ ] " : "")
            changed.insert(next, at: index + 1)
            focus(next.id)
        }
        model.setYourNotes(changed, for: info.id)
    }

    private func deleteEmpty(_ id: UUID) {
        var changed = notes
        guard let index = changed.firstIndex(where: { $0.id == id }) else { return }
        if changed[index].kind != .point {
            changed[index].text = ""
        } else if index > 0 {
            changed.remove(at: index)
            focus(changed[index - 1].id)
        } else {
            return
        }
        model.setYourNotes(changed, for: info.id)
    }

    private func move(from id: UUID, by offset: Int) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes.indices.contains(index + offset) else { return }
        focus(notes[index + offset].id)
    }

    /// On the next turn of the run loop, when a line just added is there to focus.
    private func focus(_ id: UUID?) {
        caretAtEnd = id
        Task { @MainActor in focused = id }
    }
}

private struct YourNoteLine: View {
    let note: UserNote
    @Binding var content: String
    let editable: Bool
    /// Whether it's the only line and empty, to say what a line can be.
    let prompt: Bool
    let writing: Bool
    let rightToLeft: Bool
    var focused: FocusState<UUID?>.Binding
    @Binding var caretAtEnd: UUID?
    let onReturn: () -> Void
    let onDeleteEmpty: () -> Void
    let onMove: (Int) -> Void
    @ViewState private var selection: TextSelection?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(note.words.isEmpty ? " " : timestamp(note.at))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(writing ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: YourNotesEditor.gutter, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                marker
                if editable {
                    field
                } else {
                    Text(note.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        }
        .font(note.kind == .heading ? .system(size: 19, weight: .bold) : .system(size: 15))
        .padding(.top, note.kind == .heading ? 18 : 8)
    }

    @ViewBuilder
    private var marker: some View {
        switch note.kind {
        case .heading: EmptyView()
        case .task: Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(.tertiary)
        case .point: Text(verbatim: "•").foregroundStyle(.tertiary)
        }
    }

    private var field: some View {
        TextField(
            "Note",
            text: $content,
            selection: $selection,
            prompt: prompt ? Text("Type a note. # makes a heading, and [ ] something to do.") : Text(verbatim: ""),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .focused(focused, equals: note.id)
        .onSubmit(onReturn)
        .onKeyPress(.delete) {
            guard content.isEmpty else { return .ignored }
            onDeleteEmpty()
            return .handled
        }
        .onKeyPress(.upArrow) {
            onMove(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            onMove(1)
            return .handled
        }
        .onChange(of: focused.wrappedValue == note.id) { _, now in
            guard now, caretAtEnd == note.id else { return }
            caretAtEnd = nil
            selection = TextSelection(insertionPoint: content.endIndex)
        }
    }
}
