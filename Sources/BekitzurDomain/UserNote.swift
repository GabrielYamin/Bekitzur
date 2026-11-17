import Foundation

/// A line the user wrote while recording, with when they started it, in seconds from the recording's start, so it sits
/// beside what was being said then. Bekitzur reads these when it writes the Notes.
public struct UserNote: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var at: Double
    public var text: String

    public init(id: UUID = UUID(), at: Double, text: String) {
        self.id = id
        self.at = at
        self.text = text
    }

    public enum Kind: Sendable, Equatable {
        case heading, task, point
    }

    /// A line starting with "#" is a heading, and one starting with "[ ]" or "[]" something to do.
    public var kind: Kind {
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { return .heading }
        if line.hasPrefix("[ ]") || line.hasPrefix("[]") { return .task }
        return .point
    }

    /// What it says, without a heading's "#" or a task's "[ ]".
    public var words: String {
        let line = text.trimmingCharacters(in: .whitespaces)
        let shown = switch kind {
        case .heading: String(line.drop { $0 == "#" })
        case .task: String(line.dropFirst(line.hasPrefix("[ ]") ? 3 : 2))
        case .point: line
        }
        return shown.trimmingCharacters(in: .whitespaces)
    }
}

/// Where one of the user's notes sits beside the Notes.
public enum UserNotePlace: Hashable, Sendable {
    case summary, decision(Int), actionItem(Int), openQuestion(Int)
}

extension UserNote {
    /// How long after something was said a note is still taken to be about it; written before it was said, half that.
    static let reach = 150.0

    /// Each note beside the item it's about: the item it made, or an item without turns, like one the user added, that
    /// it shares two words with; otherwise the item whose turns were said closest before it was written, within `reach`,
    /// and the rest beside the summary.
    public static func places(of notes: [UserNote], in written: Notes, turns: [Turn]) -> [UUID: UserNotePlace] {
        let starts = Dictionary(turns.compactMap { turn in turn.start.map { (turn.id, $0) } }, uniquingKeysWith: { first, _ in first })
        func times(_ sources: [String]) -> [Double] { sources.compactMap { starts[$0] } }
        var items: [Candidate] = []
        for (index, item) in written.decisions.enumerated() {
            items.append(Candidate(place: .decision(index), times: times(item.sourceTurns), text: item.text, yourNote: item.yourNote))
        }
        for (index, item) in written.actionItems.enumerated() {
            items.append(Candidate(place: .actionItem(index), times: times(item.sourceTurns), text: item.text, yourNote: item.yourNote))
        }
        for (index, item) in written.openQuestions.enumerated() {
            items.append(Candidate(place: .openQuestion(index), times: times(item.sourceTurns), text: item.text, yourNote: item.yourNote))
        }
        var places: [UUID: UserNotePlace] = [:]
        for note in notes where !note.words.isEmpty {
            let made = items.first { $0.yourNote == note.id }?.place
            places[note.id] = made ?? sharingWords(with: note, among: items) ?? closest(to: note, among: items) ?? .summary
        }
        return places
    }

    private struct Candidate {
        let place: UserNotePlace
        let times: [Double]
        let text: String
        let yourNote: UUID?
    }

    private static func sharingWords(with note: UserNote, among items: [Candidate]) -> UserNotePlace? {
        let mine = significantWords(note.words)
        var best: (place: UserNotePlace, shared: Int)?
        for item in items where item.times.isEmpty {
            let shared = mine.intersection(significantWords(item.text)).count
            if shared >= 2, shared > (best?.shared ?? 0) { best = (item.place, shared) }
        }
        return best?.place
    }

    private static func closest(to note: UserNote, among items: [Candidate]) -> UserNotePlace? {
        var best: (place: UserNotePlace, distance: Double)?
        for item in items {
            for time in item.times {
                let distance = time <= note.at ? note.at - time : (time - note.at) * 2
                if distance <= reach, distance < (best?.distance ?? .infinity) { best = (item.place, distance) }
            }
        }
        return best?.place
    }

    /// The words that say something, in any language: three letters or more, and not one of English's commonest.
    static func significantWords(_ text: String) -> Set<String> {
        let common: Set<String> = ["the", "and", "for", "with", "about", "that", "this", "from", "into", "will", "who", "what", "when"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !common.contains($0) })
    }
}
