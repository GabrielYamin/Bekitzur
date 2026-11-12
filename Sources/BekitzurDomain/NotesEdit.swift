import Foundation

/// A change the chat makes to a Conversation's Notes. Items are named by their places in the Notes as the chat saw them:
/// "D2" is the second Decision, "A1" the first Action Item, "Q3" the third Open Question.
public enum NotesEdit: Equatable, Sendable {
    public enum Section: String, Codable, Sendable {
        case decision, actionItem = "action_item", openQuestion = "open_question"

        /// The letter its items are named by.
        public var letter: Character {
            switch self {
            case .decision: "D"
            case .actionItem: "A"
            case .openQuestion: "Q"
            }
        }
    }

    case add(Section, text: String, owner: String?, due: String?)
    /// A nil field stays as it was; an empty owner or due takes it off.
    case change(item: String, text: String?, owner: String?, due: String?, done: Bool?)
    case remove(item: String)
    case title(String)
    case summary(String)
}

/// A change made to the Notes, as the chat shows it.
public struct AppliedEdit: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case added, changed, removed, title, summary
    }

    public let kind: Kind
    public let section: NotesEdit.Section?
    /// The item after the change, or before it was removed; the new title or summary.
    public let text: String

    public init(kind: Kind, section: NotesEdit.Section?, text: String) {
        self.kind = kind
        self.section = section
        self.text = text
    }
}

extension Notes {
    /// The Notes with `edits` made, and what each one that names an item in them, or none, changed. Every edit names
    /// items by their places in these Notes, so removals and additions come last, after the changes.
    /// - Parameter due: The day and time of day a due phrase says, as Action Items save them.
    public func applying(_ edits: [NotesEdit], due: (String) -> (date: String, time: String?)?) -> (notes: Notes, applied: [AppliedEdit]) {
        var notes = self
        var applied: [AppliedEdit] = []
        var removed: [NotesEdit.Section: Set<Int>] = [:]
        var added: [(section: NotesEdit.Section, text: String, owner: String?, due: String?)] = []
        for edit in edits {
            switch edit {
            case .title(let text):
                guard let text = Self.given(text), text != notes.title else { continue }
                notes.title = text
                applied.append(AppliedEdit(kind: .title, section: nil, text: text))
            case .summary(let text):
                guard let text = Self.given(text), text != notes.summary else { continue }
                notes.summary = text
                applied.append(AppliedEdit(kind: .summary, section: nil, text: text))
            case .add(let section, let text, let owner, let due):
                guard let text = Self.given(text) else { continue }
                added.append((section, text, owner, due))
                applied.append(AppliedEdit(kind: .added, section: section, text: text))
            case .remove(let item):
                guard let (section, index) = place(of: item), removed[section]?.contains(index) != true else { continue }
                removed[section, default: []].insert(index)
                applied.append(AppliedEdit(kind: .removed, section: section, text: text(of: section, at: index)))
            case .change(let item, let text, let owner, let dueSaid, let done):
                guard let (section, index) = place(of: item) else { continue }
                let newText = text.flatMap(Self.given)
                let before = notes
                switch section {
                case .decision:
                    if let newText { notes.decisions[index].text = newText }
                case .openQuestion:
                    if let newText { notes.openQuestions[index].text = newText }
                case .actionItem:
                    if let newText { notes.actionItems[index].text = newText }
                    if let owner { notes.actionItems[index].owner = Self.given(owner) }
                    if let dueSaid { Self.set(dueSaid, on: &notes.actionItems[index], due: due) }
                    // Not done is no mark, as unchecking an item in the Notes leaves it.
                    if let done { notes.actionItems[index].done = done ? true : nil }
                }
                guard notes != before else { continue }
                applied.append(AppliedEdit(kind: .changed, section: section, text: notes.text(of: section, at: index)))
            }
        }
        for index in (removed[.decision] ?? []).sorted(by: >) { notes.decisions.remove(at: index) }
        for index in (removed[.actionItem] ?? []).sorted(by: >) { notes.actionItems.remove(at: index) }
        for index in (removed[.openQuestion] ?? []).sorted(by: >) { notes.openQuestions.remove(at: index) }
        for item in added {
            switch item.section {
            case .decision:
                notes.decisions.append(Decision(text: item.text))
            case .openQuestion:
                notes.openQuestions.append(OpenQuestion(text: item.text))
            case .actionItem:
                var action = ActionItem(text: item.text, owner: item.owner.flatMap(Self.given))
                if let said = item.due { Self.set(said, on: &action, due: due) }
                notes.actionItems.append(action)
            }
        }
        return (notes, applied)
    }

    /// An item's section and index from its name, like "A2"; nil for one these Notes don't have.
    public func place(of item: String) -> (NotesEdit.Section, Int)? {
        guard let letter = item.first, let number = Int(item.dropFirst()), number >= 1 else { return nil }
        let section: NotesEdit.Section
        switch letter {
        case "D": section = .decision
        case "A": section = .actionItem
        case "Q": section = .openQuestion
        default: return nil
        }
        return number <= count(of: section) ? (section, number - 1) : nil
    }

    /// The name the item an edit added or changed has in these Notes, like "A2"; nil when they don't have it.
    public func name(of edit: AppliedEdit) -> String? {
        guard edit.kind == .added || edit.kind == .changed, let section = edit.section,
              let index = (0..<count(of: section)).first(where: { text(of: section, at: $0) == edit.text }) else { return nil }
        return "\(section.letter)\(index + 1)"
    }

    private func count(of section: NotesEdit.Section) -> Int {
        switch section {
        case .decision: decisions.count
        case .actionItem: actionItems.count
        case .openQuestion: openQuestions.count
        }
    }

    private func text(of section: NotesEdit.Section, at index: Int) -> String {
        switch section {
        case .decision: decisions[index].text
        case .actionItem: actionItems[index].text
        case .openQuestion: openQuestions[index].text
        }
    }

    /// Trimmed, and nil when that leaves nothing.
    private static func given(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The due phrase, and the day and time it says; an empty one takes the due date off.
    private static func set(_ said: String, on item: inout ActionItem, due: (String) -> (date: String, time: String?)?) {
        let phrase = given(said)
        let resolved = phrase.flatMap(due)
        item.duePhrase = phrase
        item.dueDate = resolved?.date
        item.dueTime = resolved?.time
    }
}
