import Foundation

/// Who spoke when through a Conversation, where its Notes' items were said, and where the user wrote their notes: what
/// the timeline under the Transcript and the ribbon under the Notes draw.
public struct ConversationTimeline: Equatable, Sendable {
    /// One Speaker's talk, with pauses shorter than `joined` closed, so a lane reads as turns rather than words.
    public struct Lane: Equatable, Sendable {
        public let speaker: String
        public let stretches: [ClosedRange<Double>]
    }

    public enum Kind: Equatable, Sendable {
        case decision, actionItem, openQuestion
    }

    /// A Decision, Action Item, or Open Question where it was said: where its first Source starts, or for one a note
    /// made without Sources, where the note was written.
    public struct Item: Equatable, Sendable {
        public let kind: Kind
        public let index: Int
        public let at: Double
    }

    /// Seconds, from the start of the Recording to the end of the last thing in it.
    public let length: Double
    /// In the order the Speakers first talk.
    public let lanes: [Lane]
    /// In the order they were said.
    public let items: [Item]
    /// The user's notes with words, in the order they were written.
    public let yourNotes: [UserNote]

    static let joined = 1.5

    /// - Parameters:
    ///   - transcript: With the user's fixes, so words they moved to another Speaker are in that Speaker's lane.
    ///   - length: The Recording's, when it's loaded; otherwise the end of the last thing in the timeline.
    public init(transcript: Transcript, notes written: Notes, turns: [Turn], yourNotes: [UserNote], length: Double? = nil) {
        lanes = Self.lanes(of: transcript)
        self.yourNotes = yourNotes.filter { !$0.words.isEmpty }.sorted { $0.at < $1.at }
        items = Self.items(of: written, turns: turns, yourNotes: self.yourNotes)
        let ends = lanes.compactMap { $0.stretches.last?.upperBound } + items.map(\.at) + self.yourNotes.map(\.at)
        self.length = max(length ?? 0, ends.max() ?? 0)
    }

    private static func lanes(of transcript: Transcript) -> [Lane] {
        var stretches: [String: [ClosedRange<Double>]] = [:]
        var order: [String] = []
        let said = transcript.segments.flatMap { segment -> [(speaker: String, start: Double, end: Double)] in
            let speaker = segment.speaker ?? "Speaker"
            guard let words = segment.words, !words.isEmpty else { return [(speaker, segment.start, segment.end)] }
            return words.map { (speaker, $0.start, $0.end) }
        }
        for piece in said.sorted(by: { $0.start < $1.start }) where piece.end > piece.start {
            if stretches[piece.speaker] == nil { order.append(piece.speaker) }
            var lane = stretches[piece.speaker] ?? []
            if let last = lane.last, piece.start - last.upperBound < joined {
                lane[lane.count - 1] = last.lowerBound...max(last.upperBound, piece.end)
            } else {
                lane.append(piece.start...piece.end)
            }
            stretches[piece.speaker] = lane
        }
        return order.map { Lane(speaker: $0, stretches: stretches[$0] ?? []) }
    }

    private static func items(of written: Notes, turns: [Turn], yourNotes: [UserNote]) -> [Item] {
        let starts = Dictionary(turns.compactMap { turn in turn.start.map { (turn.id, $0) } }, uniquingKeysWith: min)
        let noted = Dictionary(yourNotes.map { ($0.id, $0.at) }, uniquingKeysWith: min)
        func at(_ sources: [String], _ note: UUID?) -> Double? {
            sources.compactMap { starts[$0] }.min() ?? note.flatMap { noted[$0] }
        }
        var items: [Item] = []
        for (index, decision) in written.decisions.enumerated() {
            if let time = at(decision.sourceTurns, decision.fromYourNote) { items.append(Item(kind: .decision, index: index, at: time)) }
        }
        for (index, item) in written.actionItems.enumerated() {
            if let time = at(item.sourceTurns, item.fromYourNote) { items.append(Item(kind: .actionItem, index: index, at: time)) }
        }
        for (index, question) in written.openQuestions.enumerated() {
            if let time = at(question.sourceTurns, question.fromYourNote) { items.append(Item(kind: .openQuestion, index: index, at: time)) }
        }
        return items.sorted { ($0.at, $0.kind.order, $0.index) < ($1.at, $1.kind.order, $1.index) }
    }
}

extension ConversationTimeline.Kind {
    /// As the Notes list them: Decisions, then Action Items, then Open Questions.
    fileprivate var order: Int {
        switch self {
        case .decision: 0
        case .actionItem: 1
        case .openQuestion: 2
        }
    }
}
