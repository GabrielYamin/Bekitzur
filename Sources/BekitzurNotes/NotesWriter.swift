import BekitzurDomain
import Foundation

public enum NotesWriterError: Error, CustomStringConvertible {
    case unreadableOutput(String)

    public var description: String {
        switch self {
        case .unreadableOutput(let text): "The language model's Notes aren't valid JSON: \(text.prefix(200))…"
        }
    }
}

/// Writes a Conversation's Notes from its turns with a local language model.
public struct NotesWriter {
    private let model: LanguageModel

    public init(model: LanguageModel) {
        self.model = model
    }

    public func write(turns: [Turn], date: Date, language: ConversationLanguage, calendar: Calendar = .current) throws -> (notes: Notes, completion: Completion) {
        let completion = try model.complete(
            system: Self.instructions,
            user: Self.render(turns, date: date, language: language),
            grammar: Self.grammar,
            maxTokens: 6_000
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard var notes = try? decoder.decode(Notes.self, from: Data(completion.text.utf8)) else {
            throw NotesWriterError.unreadableOutput(completion.text)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        for i in notes.actionItems.indices {
            notes.actionItems[i].dueDate = notes.actionItems[i].duePhrase
                .flatMap { DueDateResolver.resolve($0, from: date, calendar: calendar) }
                .map(formatter.string(from:))
        }
        return (notes, completion)
    }

    /// Merges consecutive segments by the same Speaker into numbered turns.
    public static func turns(from transcript: Transcript) -> [Turn] {
        var turns: [Turn] = []
        for segment in transcript.segments {
            let speaker = segment.speaker ?? "Speaker"
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].text += " " + segment.text
                turns[turns.count - 1].end = segment.end
            } else {
                turns.append(Turn(id: String(format: "T%03d", turns.count + 1), speaker: speaker, text: segment.text, start: segment.start, end: segment.end))
            }
        }
        return turns
    }

    static func render(_ turns: [Turn], date: Date, language: ConversationLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        let lines = turns.map { "[\($0.id)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        return """
        Conversation date: \(formatter.string(from: date))
        Language: \(language == .hebrew ? "Hebrew" : "English")

        Transcript:
        \(lines)
        """
    }

    static let instructions = """
    You are the note-taker for a recorded work conversation. You get a transcript with numbered speaker turns like [T012]. Speakers are either named people or unnamed voices such as "Speaker 2".

    Write the Notes in English, even when the conversation is in Hebrew: every field is English except "quote", which stays verbatim in the transcript's original language.

    Extract:
    - title: a short title for the conversation.
    - summary: 3 to 6 sentences.
    - decisions: conclusions the participants actually reached. If a decision changed during the conversation, report only the final version.
    - action_items: concrete commitments or assignments. For each: what needs doing, the owner, and when it's due.
      - The owner is the person who will do the work. If a speaker commits ("I'll do it"), the owner is that speaker's label exactly as written in the transcript, even if it is "Speaker 2". If the group assigns it to someone by name, the owner is that person, even if they are not in the conversation. If someone asks or arranges for another person to do the work, the owner is the person doing the work, not the person passing on the request. Use null if nobody took it.
      - due_phrase: the words that say when it's due, copied exactly as spoken (for example "עד יום חמישי", "by Friday", "מחר בבוקר"), or null if no time was given. Don't turn it into a date.
      - Leave out hypothetical ideas, jokes, things already done, offers nobody accepted, vague suggestions nobody took on, and anything cancelled later in the conversation.
    - open_questions: questions that were raised and left unresolved.

    For every decision, action item, and open question, give the turn IDs where it was established (for example "T012"). For decisions and action items, also give a short verbatim quote from those turns. Never add anything that is not in the transcript.
    """

    /// GBNF for the Notes JSON, so the output always parses.
    static let grammar = #"""
    root ::= "{" ws "\"title\":" ws str "," ws "\"summary\":" ws str "," ws "\"decisions\":" ws decisions "," ws "\"action_items\":" ws actions "," ws "\"open_questions\":" ws questions ws "}"
    decisions ::= "[" ws "]" | "[" ws decision ("," ws decision)* ws "]"
    decision ::= "{" ws "\"text\":" ws str "," ws "\"source_turns\":" ws turns "," ws "\"quote\":" ws str ws "}"
    actions ::= "[" ws "]" | "[" ws action ("," ws action)* ws "]"
    action ::= "{" ws "\"text\":" ws str "," ws "\"owner\":" ws optstr "," ws "\"due_phrase\":" ws optstr "," ws "\"source_turns\":" ws turns "," ws "\"quote\":" ws str ws "}"
    questions ::= "[" ws "]" | "[" ws question ("," ws question)* ws "]"
    question ::= "{" ws "\"text\":" ws str "," ws "\"source_turns\":" ws turns ws "}"
    turns ::= "[" ws "]" | "[" ws turn ("," ws turn)* ws "]"
    turn ::= "\"T" [0-9] [0-9] [0-9] [0-9]? "\""
    optstr ::= str | "null"
    str ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n]{0,20}
    """#
}
