import BekitzurDomain
import SwiftUI

/// Above the Conversation list, a search field that's always there, for titles, Notes, and Transcripts (⌥⌘F; ⌘F is Find
/// in the Transcript), with the People filter inside it, which shows only Conversations with everyone picked, and
/// Refresh beside it. While people are picked, a line under it says who, since the filter is only an icon.
struct ConversationListHeader: View {
    @Bindable var model: AppModel
    @ViewState private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        focused = true
                    } label: {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .help("Search Conversations (⌥⌘F)")
                    TextField("Search Conversations", text: $model.filter.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onExitCommand {
                            model.filter.query = ""
                            focused = false
                        }
                    if !model.filter.query.isEmpty {
                        Button {
                            model.filter.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop searching")
                    }
                    Button {
                        picking.toggle()
                    } label: {
                        Image(systemName: model.filter.people.isEmpty ? "person.2" : "person.2.fill")
                            .foregroundStyle(model.filter.people.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.filter.people.isEmpty ? String(localized: "Show only Conversations with the people you pick") : peopleLabel)
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        PeopleChecklist(model: model).frame(width: 250).padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help("Read the Conversations folder again, for Conversations added or changed outside Bekitzur (⌘R)")
            }
            if !model.filter.people.isEmpty {
                HStack(spacing: 6) {
                    Label(peopleLabel, systemImage: "person.2.fill").foregroundStyle(.tint)
                    Spacer(minLength: 4)
                    Button("Show everyone's Conversations") { model.filter.people = [] }.buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }
        }
    }

    /// Who's picked, for the line under the field.
    private var peopleLabel: String {
        let people = model.filter.people
        if people.count == 1 { return String(localized: "With \(people[0])") }
        return String(localized: "With \(people[0]) + \(people.count - 1)")
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
