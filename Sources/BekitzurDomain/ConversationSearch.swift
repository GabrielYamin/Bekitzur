import Foundation

/// What a Conversation can be found by in the list: the people in it and what it says.
public struct SearchEntry: Sendable, Equatable {
    /// Its Speakers with a confirmed name, other than the user: someone with only a suggested name, or none, isn't known
    /// to have been there.
    public var people: Set<String>
    /// The Notes' text, then the Transcript's lines.
    public var lines: [String]

    public init(people: Set<String>, lines: [String]) {
        self.people = people
        self.lines = lines
    }

    public init(_ result: ProcessedConversation, user: String) {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        people = Set(result.speakers.compactMap { speaker in
            guard case .named(let name, _) = speaker.naming, name.caseInsensitiveCompare(user) != .orderedSame else { return nil }
            return name
        })
        let notes = result.notes
        lines = [notes.summary] + notes.decisions.map(\.text) + notes.actionItems.map(\.text) + notes.openQuestions.map(\.text)
            + result.transcript.segments.map(\.text)
    }
}

/// The Conversation list narrowed to the people picked, every one of them in each Conversation shown, and to a search
/// of titles, Notes, and Transcripts that ignores case and niqqud.
public struct ConversationFilter: Sendable, Equatable {
    public var people: [String] = []
    public var query = ""

    public init(people: [String] = [], query: String = "") {
        self.people = people
        self.query = query
    }

    public var isActive: Bool { !people.isEmpty || !searched.isEmpty }

    private var searched: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func matches(title: String, entry: SearchEntry?) -> Bool {
        let known = entry?.people ?? []
        guard people.allSatisfy(known.contains) else { return false }
        let searched = searched
        return searched.isEmpty || Self.has(searched, in: title) || (entry?.lines ?? []).contains { Self.has(searched, in: $0) }
    }

    /// The line the search was found in inside a Conversation, around the match; nil when it's in the title.
    public func excerpt(title: String, entry: SearchEntry?) -> Excerpt? {
        let searched = searched
        guard !searched.isEmpty, !Self.has(searched, in: title) else { return nil }
        for line in entry?.lines ?? [] {
            guard let match = line.range(of: searched, options: Self.options) else { continue }
            let start = line.index(match.lowerBound, offsetBy: -30, limitedBy: line.startIndex) ?? line.startIndex
            let end = line.index(match.upperBound, offsetBy: 70, limitedBy: line.endIndex) ?? line.endIndex
            return Excerpt(
                before: (start > line.startIndex ? "…" : "") + line[start..<match.lowerBound],
                match: String(line[match]),
                after: line[match.upperBound..<end] + (end < line.endIndex ? "…" : "")
            )
        }
        return nil
    }

    public struct Excerpt: Sendable, Equatable {
        public var before: String
        public var match: String
        public var after: String
    }

    /// Everyone in the Conversations, by how many they're in, then by name.
    public static func people(in entries: some Sequence<SearchEntry>) -> [(name: String, conversations: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries { for name in entry.people { counts[name, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.localizedCompare($1.0) == .orderedAscending }
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func has(_ searched: String, in text: String) -> Bool {
        text.range(of: searched, options: options) != nil
    }
}
