import Foundation

public enum ConversationStatus: String, Codable, Sendable {
    case recording, processing, unreviewed, reviewed, failed
}

/// A Conversation as listed in the library.
public struct ConversationInfo: Codable, Identifiable, Sendable, Hashable {
    /// The folder name, from the start time: "2026-10-19-143012".
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var language: ConversationLanguage
    /// How many people spoke, when the user said; otherwise speaker separation decides.
    public var people: Int?
    public var status: ConversationStatus
    /// What processing is doing right now, while status is processing.
    public var step: String?
    public var title: String?
    public var error: String?
    /// Something the user should check, like a track that recorded only silence.
    public var warning: String?
    /// Seconds the microphone track plays later than the system audio track so a call's two tracks line up: 0 for
    /// recordings lined up while recording, measured once for earlier ones, nil until then.
    public var microphoneDelay: Double?

    public init(id: String, startedAt: Date, language: ConversationLanguage, status: ConversationStatus) {
        self.id = id
        self.startedAt = startedAt
        self.language = language
        self.status = status
    }
}

/// A Speaker found in one Conversation, kept with its embedding so the user can name it later.
public struct ConversationSpeaker: Codable, Sendable, Equatable {
    public var label: String
    public var speechSeconds: Double
    public var embedding: [Float]
    public var naming: SpeakerNaming

    public init(label: String, speechSeconds: Double, embedding: [Float], naming: SpeakerNaming) {
        self.label = label
        self.speechSeconds = speechSeconds
        self.embedding = embedding
        self.naming = naming
    }

    public var displayName: String {
        if case .named(let name, _) = naming { return name }
        return label
    }
}

/// Everything processing produces for a Conversation.
public struct ProcessedConversation: Codable, Sendable, Equatable {
    public var transcript: Transcript
    public var speakers: [ConversationSpeaker]
    /// The numbered turns the Notes' Sources point to, from the Transcript with the user's fixes applied.
    public var turns: [Turn]
    public var notes: Notes
    /// The user's fixes to the Transcript when the Notes were written; the Notes are behind when these differ.
    public var notesFixes: Set<TranscriptFlags.Word>?

    public init(transcript: Transcript, speakers: [ConversationSpeaker], turns: [Turn], notes: Notes, notesFixes: Set<TranscriptFlags.Word>? = nil) {
        self.transcript = transcript
        self.speakers = speakers
        self.turns = turns
        self.notes = notes
        self.notesFixes = notesFixes
    }

    /// Shows a Speaker under a new name everywhere: Transcript, turns, Owners, and the Notes' text.
    public func renamingSpeaker(_ label: String, to name: String) -> ProcessedConversation {
        guard let index = speakers.firstIndex(where: { $0.label == label }) else { return self }
        let old = speakers[index].displayName
        var result = self
        result.speakers[index].naming = .named(name, similarity: 1)
        guard old != name else { return result }

        let pattern = "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: old))(?![\\p{L}\\p{N}])"
        guard let mention = try? NSRegularExpression(pattern: pattern) else { return result }
        func replace(_ text: String) -> String {
            mention.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: name)
            )
        }

        for i in result.transcript.segments.indices where result.transcript.segments[i].speaker == old {
            result.transcript.segments[i].speaker = name
        }
        for i in result.turns.indices where result.turns[i].speaker == old {
            result.turns[i].speaker = name
        }
        result.notes.title = replace(result.notes.title)
        result.notes.summary = replace(result.notes.summary)
        for i in result.notes.decisions.indices {
            result.notes.decisions[i].text = replace(result.notes.decisions[i].text)
        }
        for i in result.notes.actionItems.indices {
            if result.notes.actionItems[i].owner == old { result.notes.actionItems[i].owner = name }
            result.notes.actionItems[i].text = replace(result.notes.actionItems[i].text)
        }
        for i in result.notes.openQuestions.indices {
            result.notes.openQuestions[i].text = replace(result.notes.openQuestions[i].text)
        }
        result.notesFixes = result.notesFixes.map { fixes in
            Set(fixes.map { fix in
                var fix = fix
                if fix.saidBy == old { fix.saidBy = name }
                return fix
            })
        }
        return result
    }
}
