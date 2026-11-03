// PROTOTYPE, throwaway: three ways to filter the Conversation list by the people in it, on the branch
// prototype/people-filter only. Switch with the bar at the bottom of the main window (⌘[ and ⌘]); it shows only with
// `defaults write app.bekitzur.mac prototypes -bool true`. The people of a Conversation are its Speakers with a confirmed
// name, without the user (Settings → Your name); Speakers with only a suggested name or none don't count.

import BekitzurDomain
import BekitzurLibrary
import SwiftUI

enum PeopleFilterVariant: String, CaseIterable {
    case menu = "A", search = "B", section = "C"

    var name: String {
        switch self {
        case .menu: "People button and chips"
        case .search: "People as search tokens"
        case .section: "People section in the sidebar"
        }
    }

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "prototypes") }
}

/// Who was in each Conversation, and everyone by how many Conversations they were in.
struct PeopleIndex: Sendable {
    var byConversation: [String: Set<String>] = [:]
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
            }
            var counts: [String: Int] = [:]
            for names in index.byConversation.values { for name in names { counts[name, default: 0] += 1 } }
            index.people = counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            return index
        }.value
    }
}

/// The filter all three variants share, so switching keeps what's picked.
struct PeopleFilter {
    var index = PeopleIndex()
    var selected: [String] = []
    /// Variant B's typed text, which also matches titles.
    var query = ""

    var isActive: Bool { !selected.isEmpty || !query.isEmpty }

    func matches(_ info: ConversationInfo) -> Bool {
        let people = index.byConversation[info.id] ?? []
        guard selected.allSatisfy(people.contains) else { return false }
        return query.isEmpty || info.displayTitle.localizedCaseInsensitiveContains(query)
    }

    mutating func toggle(_ name: String) {
        if let i = selected.firstIndex(of: name) { selected.remove(at: i) } else { selected.append(name) }
    }
}

struct PersonToken: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

// MARK: Variant A: a People button with a checklist, and the people picked as removable chips

struct PeopleMenuFilter: View {
    @Binding var filter: PeopleFilter
    @ViewState private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    picking.toggle()
                } label: {
                    Label(filter.selected.isEmpty ? "People" : "People (\(filter.selected.count))", systemImage: "person.2")
                }
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    PeopleChecklist(filter: $filter).frame(width: 240).padding(10)
                }
                Spacer()
                if !filter.selected.isEmpty {
                    Button("Clear") { filter.selected = [] }.buttonStyle(.borderless).font(.caption)
                }
            }
            if !filter.selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(filter.selected, id: \.self) { name in
                        Button {
                            filter.toggle(name)
                        } label: {
                            HStack(spacing: 3) {
                                Text(name)
                                Image(systemName: "xmark").font(.caption2.bold())
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
        }
    }
}

// MARK: Variant B: people as tokens in the search field, which also matches titles

struct PeopleSearch: ViewModifier {
    @Binding var filter: PeopleFilter

    func body(content: Content) -> some View {
        content.searchable(
            text: $filter.query,
            tokens: Binding(get: { filter.selected.map(PersonToken.init) }, set: { filter.selected = $0.map(\.name) }),
            suggestedTokens: .constant(suggestions),
            placement: .sidebar,
            prompt: "Search, or type a name"
        ) { token in
            Label(token.name, systemImage: "person")
        }
    }

    private var suggestions: [PersonToken] {
        filter.index.people
            .filter { !filter.selected.contains($0.name) && (filter.query.isEmpty || $0.name.localizedCaseInsensitiveContains(filter.query)) }
            .map { PersonToken(name: $0.name) }
    }
}

struct PeopleSearchIfShown: ViewModifier {
    let shown: Bool
    @Binding var filter: PeopleFilter

    func body(content: Content) -> some View {
        if shown { content.modifier(PeopleSearch(filter: $filter)) } else { content }
    }
}

// MARK: Variant C: a People section above the Conversations, one person at a time, like Mail's mailboxes

struct PeopleSection: View {
    @Binding var filter: PeopleFilter

    var body: some View {
        Section("People") {
            if filter.index.people.isEmpty {
                Text("Name Speakers to see them here").foregroundStyle(.secondary)
            }
            ForEach(filter.index.people, id: \.name) { person in
                let picked = filter.selected == [person.name]
                Button {
                    filter.selected = picked ? [] : [person.name]
                } label: {
                    HStack {
                        Label(person.name, systemImage: picked ? "person.fill" : "person")
                        Spacer()
                        Text("\(person.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(picked ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
