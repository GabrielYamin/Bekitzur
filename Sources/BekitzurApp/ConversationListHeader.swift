import BekitzurDomain
import SwiftUI

/// Above the Conversation list: its title, which a magnifying glass (⌥⌘F; ⌘F is Find in the Transcript) turns into a
/// search of titles, Notes, and Transcripts, and the People menu, which shows only Conversations with everyone picked.
struct ConversationListHeader: View {
    @Bindable var model: AppModel
    @ViewState private var searching = false
    @ViewState private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if searching {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Conversations", text: $model.filter.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onExitCommand(perform: stopSearching)
                    Button(action: stopSearching) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop searching")
                }
            } else {
                Text("Conversations").fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button {
                    searching = true
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .help("Search Conversations (⌥⌘F)")
            }
            Button {
                picking.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.filter.people.isEmpty ? "person.2" : "person.2.fill")
                    Text(peopleLabel)
                    Image(systemName: "chevron.down").font(.caption2.bold())
                }
                .foregroundStyle(model.filter.people.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Show only Conversations with the people you pick")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                PeopleChecklist(model: model).frame(width: 250).padding(12)
            }
        }
        .font(.subheadline)
        .onChange(of: searching) { _, now in
            if now { focused = true }
        }
    }

    private var peopleLabel: String {
        let people = model.filter.people
        return switch people.count {
        case 0: String(localized: "People")
        case 1: String(localized: "With \(people[0])")
        default: String(localized: "With \(people[0]) + \(people.count - 1)")
        }
    }

    private func stopSearching() {
        model.filter.query = ""
        searching = false
    }
}

/// Under a Conversation in the list, the line a search was found in inside it, with the match in bold.
struct SearchExcerpt: View {
    let excerpt: ConversationFilter.Excerpt

    var body: some View {
        var match = AttributedString(excerpt.match)
        match.font = .caption.bold()
        match.foregroundColor = .primary
        var text = AttributedString(excerpt.before)
        text.append(match)
        text.append(AttributedString(excerpt.after))
        let line = excerpt.before + excerpt.match + excerpt.after
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, line.isMostlyRightToLeft ? .rightToLeft : .leftToRight)
            .padding(.bottom, 3)
    }
}

/// Everyone named in the Conversations, but the user, with how many Conversations each is in.
private struct PeopleChecklist: View {
    @Bindable var model: AppModel

    var body: some View {
        let people = ConversationFilter.people(in: model.searchEntries.values)
        VStack(alignment: .leading, spacing: 6) {
            Text("Conversations with").font(.headline)
            if people.isEmpty {
                Text("No one yet. Name Speakers in a Conversation to find its Conversations by them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(people, id: \.name) { person in
                        Toggle(isOn: Binding(get: { model.filter.people.contains(person.name) }, set: { picked in
                            if picked { model.filter.people.append(person.name) } else { model.filter.people.removeAll { $0 == person.name } }
                        })) {
                            HStack {
                                Text(person.name)
                                Spacer()
                                Text("\(person.conversations)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            if model.filter.people.count > 1 {
                Text("Each Conversation shown has all of them.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.filter.people.isEmpty {
                Button("Show everyone's Conversations") { model.filter.people = [] }.buttonStyle(.link)
            }
        }
    }
}
