// PROTOTYPE, throwaway, on the branch prototype/people-filter only: searching Conversations alongside the People menu in
// the list's header (D, picked from the first round: A, a People button with chips; B, people as search tokens; C, a
// People section in the sidebar; all in this branch's history). Switch with the bar at the bottom of the main window
// (⌘[ and ⌘]); it shows only with `defaults write app.bekitzur.mac prototypes -bool true`. The people of a Conversation
// are its Speakers with a confirmed name, without the user (Settings → Your name). Search matches titles, Notes, and
// Transcripts; a match inside a Conversation shows the line it's in under the row.

import BekitzurDomain
import BekitzurLibrary
import SwiftUI

enum PeopleFilterVariant: String, CaseIterable {
    case toolbar = "E", sidebar = "F", header = "G"

    var name: String {
        switch self {
        case .toolbar: "Search in the toolbar"
        case .sidebar: "Search field above the list"
        case .header: "Search button in the list's header"
        }
    }

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "prototypes") }
}

/// Who was in each Conversation and what it says, and everyone by how many Conversations they were in.
struct PeopleIndex: Sendable {
    var byConversation: [String: Set<String>] = [:]
    /// The Notes' text, then the Transcript's lines.
    var lines: [String: [String]] = [:]
    var people: [(name: String, count: Int)] = []

    static func build(_ conversations: [ConversationInfo], library: ConversationLibrary, me: String) async -> PeopleIndex {
        await Task.detached(priority: .userInitiated) {
            var index = PeopleIndex()
            let me = me.trimmingCharacters(in: .whitespacesAndNewlines)
            for info in conversations where info.status == .unreviewed || info.status == .reviewed {
                guard let result = library.result(for: info.id) else { continue }
                index.byConversation[info.id] = Set(result.speakers.compactMap { speaker -> String? in
                    guard case .named(let name, _) = speaker.naming else { return nil }
                    return name.caseInsensitiveCompare(me) == .orderedSame ? nil : name
                })
                let notes = result.notes
                index.lines[info.id] = [notes.summary]
                    + notes.decisions.map(\.text) + notes.actionItems.map(\.text) + notes.openQuestions.map(\.text)
                    + result.transcript.segments.map(\.text)
            }
            var counts: [String: Int] = [:]
            for names in index.byConversation.values { for name in names { counts[name, default: 0] += 1 } }
            index.people = counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            return index
        }.value
    }
}

/// The People menu's picks and the search, which every variant shares.
struct PeopleFilter {
    var index = PeopleIndex()
    var selected: [String] = []
    var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    func matches(_ info: ConversationInfo) -> Bool {
        let people = index.byConversation[info.id] ?? []
        guard selected.allSatisfy(people.contains) else { return false }
        let query = trimmedQuery
        guard !query.isEmpty else { return true }
        return Self.contains(info.displayTitle, query) || (index.lines[info.id] ?? []).contains { Self.contains($0, query) }
    }

    /// The line a search matched inside a Conversation, around the match, which is bold; nil when the title matched.
    func snippet(for info: ConversationInfo) -> AttributedString? {
        let query = trimmedQuery
        guard !query.isEmpty, !Self.contains(info.displayTitle, query),
              let line = index.lines[info.id]?.first(where: { Self.contains($0, query) }),
              let match = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        let start = line.index(match.lowerBound, offsetBy: -30, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(match.upperBound, offsetBy: 70, limitedBy: line.endIndex) ?? line.endIndex
        let excerpt = (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
        var text = AttributedString(excerpt)
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .caption.bold()
            text[range].foregroundColor = .primary
        }
        return text
    }

    mutating func toggle(_ name: String) {
        if let i = selected.firstIndex(of: name) { selected.remove(at: i) } else { selected.append(name) }
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private struct PeopleChecklist: View {
    @Binding var filter: PeopleFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conversations with").font(.headline)
            if filter.index.people.isEmpty {
                Text("No one yet. Name Speakers in a Conversation to filter by them.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(filter.index.people, id: \.name) { person in
                Toggle(isOn: Binding(get: { filter.selected.contains(person.name) }, set: { _ in filter.toggle(person.name) })) {
                    HStack {
                        Text(person.name)
                        Spacer()
                        Text("\(person.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("With more than one picked, a Conversation has to have all of them.").font(.caption).foregroundStyle(.secondary)
            if !filter.selected.isEmpty {
                Button("Show everyone's Conversations") { filter.selected = [] }.buttonStyle(.link)
            }
        }
    }
}

// MARK: D, the People menu on the right of the list's header, with G's search button beside it

struct PeopleHeaderFilter: View {
    @Binding var filter: PeopleFilter
    /// G: a magnifying glass that turns the header's title into a search field.
    let searchInHeader: Bool
    @ViewState private var picking = false
    @ViewState private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if searchInHeader && searching {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Conversations", text: $filter.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit {}
                    Button {
                        filter.query = ""
                        searching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop searching")
                }
                .font(.subheadline)
                .onAppear { focused = true }
            } else {
                Text("Conversations").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if searchInHeader {
                    Button {
                        searching = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search Conversations")
                }
            }
            Button {
                picking.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: filter.selected.isEmpty ? "person.2" : "person.2.fill")
                    Text(label)
                    Image(systemName: "chevron.down").font(.caption2.bold())
                }
                .font(.subheadline)
                .foregroundStyle(filter.selected.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                PeopleChecklist(filter: $filter).frame(width: 240).padding(10)
            }
        }
    }

    private var label: String {
        switch filter.selected.count {
        case 0: "People"
        case 1: "With \(filter.selected[0])"
        default: "With \(filter.selected[0]) + \(filter.selected.count - 1)"
        }
    }
}

// MARK: F, a search field between Record and Import and the list

struct SidebarSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Conversations", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: E, the search field in the window's toolbar

struct ToolbarSearchIfShown: ViewModifier {
    let shown: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if shown {
            content.searchable(text: $query, placement: .toolbar, prompt: "Search Conversations")
        } else {
            content
        }
    }
}

// MARK: The switcher

struct PrototypeSwitcher: View {
    @Binding var variant: PeopleFilterVariant
    let state: String

    var body: some View {
        HStack(spacing: 14) {
            Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
            VStack(spacing: 1) {
                Text("\(variant.rawValue) · \(variant.name)").font(.callout.bold())
                Text(state).font(.caption).opacity(0.8)
            }
            .frame(minWidth: 260)
            Button { cycle(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: Capsule())
        .shadow(radius: 8)
        .help("Prototype: ⌘[ and ⌘] switch between the variants")
    }

    private func cycle(_ step: Int) {
        let all = PeopleFilterVariant.allCases
        let i = all.firstIndex(of: variant) ?? 0
        variant = all[(i + step + all.count) % all.count]
    }
}
