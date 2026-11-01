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

    /// - Returns: The Notes, and the draft they were checked from.
    public func write(turns: [Turn], date: Date, language: ConversationLanguage, calendar: Calendar = .current) throws -> (notes: Notes, draft: Notes, completion: Completion) {
        let completion = try model.startChat(
            system: Self.instructions,
            user: Self.render(turns, date: date, language: language),
            grammar: Self.grammar,
            maxTokens: 6_000,
            followUp: Self.reviewTokens
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let draft = try? decoder.decode(Notes.self, from: Data(completion.text.utf8)).withoutTurnIDsInText else {
            throw NotesWriterError.unreadableOutput(completion.text)
        }
        var notes = reviewed(draft, turns: turns)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        for i in notes.actionItems.indices {
            notes.actionItems[i].dueDate = notes.actionItems[i].duePhrase
                .flatMap { DueDateResolver.resolve($0, from: date, calendar: calendar) }
                .map(formatter.string(from:))
        }
        return (notes, draft, completion)
    }

    /// Room for the checks after the draft: the decisions and action items, then each open question, whose message shows
    /// up to 900 words said after it, about 4,000 tokens in Hebrew, so this covers about two of them. Checks that don't
    /// fit leave their items as drafted. More room grew the context past its first 32K for a 3,000-token Transcript,
    /// for the same Notes, where this keeps it there up to about an hour of Hebrew.
    static let reviewTokens = 12_288

    /// The draft checked in the same chat, which still holds the transcript, since one pass over a long transcript leaves
    /// items like "We'll do it tomorrow" as they were said and lists questions that were answered later on. Decisions and
    /// action items are checked first, then each open question on its own: asked together, wording for one changed the
    /// model's answers about the other. The draft stands where the context is full or a reply doesn't decode.
    private func reviewed(_ draft: Notes, turns: [Turn]) -> Notes {
        var notes = draft
        let items = Self.reviewItems(draft)
        if !items.isEmpty,
           let reply = try? model.continueChat(user: Self.reviewRequest(items), grammar: Self.reviewGrammar(items), maxTokens: 2_000),
           let checked = try? JSONDecoder().decode([CheckedItem].self, from: Data(reply.text.utf8)),
           checked.count == items.count {
            notes = Self.apply(checked, of: items, to: notes)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        notes.openQuestions = draft.openQuestions.enumerated().filter { offset, question in
            let request = Self.questionRequest(question, number: offset + 1, of: draft.openQuestions.count, turns: turns)
            guard let reply = try? model.continueChat(user: request, grammar: Self.questionGrammar, maxTokens: 100),
                  let check = try? decoder.decode(CheckedQuestion.self, from: Data(reply.text.utf8))
            else { return true }
            guard check.kind == "open" else { return false }
            guard let answer = Self.laterAnswer(to: question, check, turns: turns),
                  let verdict = try? model.continueChat(user: Self.answerRequest(question, answer), grammar: Self.answerGrammar, maxTokens: 20),
                  let answered = try? JSONDecoder().decode(Verdict.self, from: Data(verdict.text.utf8))
            else { return true }
            return !answered.answers
        }.map(\.element)
        return notes
    }

    struct ReviewItem {
        enum Kind { case decision, actionItem }
        let kind: Kind
        let index: Int
        let text: String
        let sources: [String]
    }

    struct CheckedItem: Decodable {
        let item: Int
        let text: String?
    }

    /// An open question checked against the rest of the transcript.
    struct CheckedQuestion: Decodable {
        /// The later turn that answers it, by the model.
        let answeredIn: String?
        /// "open", or "hypothetical", "rhetorical", or "discussion".
        let kind: String
    }

    static func reviewItems(_ notes: Notes) -> [ReviewItem] {
        notes.decisions.enumerated().map { ReviewItem(kind: .decision, index: $0.offset, text: $0.element.text, sources: $0.element.sourceTurns) }
            + notes.actionItems.enumerated().map { ReviewItem(kind: .actionItem, index: $0.offset, text: $0.element.text, sources: $0.element.sourceTurns) }
    }

    static func reviewRequest(_ items: [ReviewItem]) -> String {
        func list(_ kind: ReviewItem.Kind, _ title: String) -> String? {
            let lines = items.enumerated().filter { $0.element.kind == kind }
                .map { "\($0.offset + 1). \($0.element.text) (\($0.element.sources.joined(separator: ", ")))" }
            return lines.isEmpty ? nil : "\(title):\n" + lines.joined(separator: "\n")
        }
        let lists = [list(.decision, "Decisions"), list(.actionItem, "Action items")].compactMap { $0 }
        return """
        Check each decision and action item of these Notes against the transcript.

        \(lists.joined(separator: "\n\n"))

        - Rewrite an item only if it says "it", "this", "that", or the like instead of naming the thing. Then read the turns before its source and name what was decided or what will be done. Copy every other item exactly, and never change a name, a number, or a technical term. Every item is in English.
        - A decision the participants didn't make, like a fact, an opinion, or how things work today: null.

        Reply with every item in order: its number and its text without the turn IDs, or null.
        """
    }

    /// One open question with what was said from where it was asked on, in the message itself: Gemma's sliding-window
    /// layers see only the last 1,024 tokens, so in a later message the transcript reaches only its few global layers, and
    /// asked from there the model rarely found an answer that came from another speaker in other words.
    static func questionRequest(_ question: OpenQuestion, number: Int, of count: Int, turns: [Turn]) -> String {
        let position = Dictionary(turns.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let asked = question.sourceTurns.compactMap { position[$0] }.min() ?? 0
        var lines: [String] = []
        var words = 0
        for turn in turns[min(asked, turns.count)...] where lines.count < 30 && words < 900 {
            let all = turn.text.split(separator: " ")
            // The question can be anywhere in its own turn; later turns usually answer early, if at all.
            let shown = lines.isEmpty ? all.suffix(300) : all.prefix(80)
            words += shown.count
            let text = shown.joined(separator: " ") + (shown.count < all.count && !lines.isEmpty ? " …" : "")
            lines.append("[\(turn.id)] \(turn.speaker): \(text)")
        }
        return """
        Open question \(number) of \(count): \(question.text) (\(question.sourceTurns.joined(separator: ", ")))

        What was said from there on:
        \(lines.joined(separator: "\n"))

        Does a turn after the question answer it? An answer usually comes from someone other than whoever asked, often without the question's words, and the speaker names in the transcript can be wrong. Deciding what to do meanwhile doesn't answer it. Give answered_in, the turn that answers it, or null if none does. Then give its kind: "open" for a question about the work that someone still has to answer, decide, or find out, or "hypothetical", "rhetorical", or "discussion" for one asked to imagine something, to make a point, or to start a discussion. A question about the field, the company, or careers in general, that nobody has to act on, is a discussion question.
        """
    }

    static let questionGrammar = #"""
    root ::= "{" ws "\"answered_in\":" ws (turn | "null") "," ws "\"kind\":" ws kind ws "}"
    turn ::= "\"T" [0-9] [0-9] [0-9] [0-9]? "\""
    kind ::= "\"open\"" | "\"hypothetical\"" | "\"rhetorical\"" | "\"discussion\""
    ws ::= [ \t\n]{0,20}
    """#

    /// The turn the model says answers the question, if it's in the transcript and after the turns the question came from.
    static func laterAnswer(to question: OpenQuestion, _ check: CheckedQuestion, turns: [Turn]) -> Turn? {
        let position = Dictionary(turns.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let asked = question.sourceTurns.compactMap { position[$0] }.max() ?? -1
        guard let answer = check.answeredIn.flatMap({ position[$0] }), answer > asked else { return nil }
        return turns[answer]
    }

    /// The one turn the search named, on its own: searching, the model calls nearly any reply an answer, like "Build
    /// Parquet only for now" to "Will product want CSV too?"; shown the turn alone, it tells the two apart.
    static func answerRequest(_ question: OpenQuestion, _ turn: Turn) -> String {
        """
        Does this turn answer the question "\(question.text)"?

        [\(turn.id)] \(turn.speaker): \(turn.text.split(separator: " ").prefix(300).joined(separator: " "))

        It answers it only if whoever asked now knows the answer. A turn that says nobody knows yet, that it depends on something else, or that decides what to do in the meantime doesn't.
        """
    }

    static let answerGrammar = #"root ::= "{" [ \t\n]* "\"answers\":" [ \t\n]* ("true" | "false") [ \t\n]* "}""#

    struct Verdict: Decodable {
        let answers: Bool
    }

    /// One entry per item in order; action items can only be rewritten.
    static func reviewGrammar(_ items: [ReviewItem]) -> String {
        let entries = items.enumerated().map { offset, item in
            let text = item.kind == .actionItem ? "str" : #"(str | "null")"#
            return #"item\#(offset + 1) ::= "{" ws "\"item\":" ws "\#(offset + 1)" "," ws "\"text\":" ws \#(text) ws "}""#
        }
        let root = #"root ::= "[" ws "# + items.indices.map { "item\($0 + 1)" }.joined(separator: #" "," ws "#) + #" ws "]""#
        return ([root] + entries + [jsonText]).joined(separator: "\n")
    }

    static func apply(_ checked: [CheckedItem], of items: [ReviewItem], to draft: Notes) -> Notes {
        var notes = draft
        notes.decisions = []
        for (item, answer) in zip(items, checked) {
            let text = withoutTurnIDs(answer.text ?? "")
            switch item.kind {
            case .decision where !text.isEmpty:
                var decision = draft.decisions[item.index]
                decision.text = text
                notes.decisions.append(decision)
            case .actionItem where !text.isEmpty:
                notes.actionItems[item.index].text = text
            default:
                break
            }
        }
        return notes
    }

    /// Text without the turn IDs that the model sometimes puts after it, like "(T029)", copying how turns are listed.
    static func withoutTurnIDs(_ text: String) -> String {
        text.replacing(/\s*\((T\d+(,\s*)?)+\)\s*$/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    Write the Notes in English, even when the conversation is in Hebrew: every field is English except "quote", which stays verbatim in the transcript's original language. Never copy a quote into another field; say in English what it means.

    Each decision, action item, and open question must make sense to a colleague who missed the conversation and reads only that item. People refer back with words like "it", "this", "that one", or "the thing from before"; read the turns before it to find what they mean, and name it. "We'll do it tomorrow" says nothing; "Run the database migration tomorrow" does.

    Extract:
    - title: a short title for the conversation.
    - summary: 3 to 6 sentences.
    - decisions: what the participants agreed on: a choice, a plan, or a change they settled. If a decision changed during the conversation, report only the final version. Someone taking on a task ("I'll take it") is an action item for that person, not a decision.
    - action_items: concrete commitments or assignments. For each: what needs doing, the owner, and when it's due.
      - The owner is the person who will do the work. If a speaker commits ("I'll do it"), the owner is that speaker's label exactly as written in the transcript, even if it is "Speaker 2". If the group assigns it to someone by name, the owner is that person, even if they are not in the conversation. If someone asks or arranges for another person to do the work, the owner is the person doing the work, not the person passing on the request. Use null if nobody took it.
      - due_phrase: the words that say when it's due, copied exactly as spoken (for example "עד יום חמישי", "by Friday", "מחר בבוקר"), or null if no time was given. Don't turn it into a date.
      - Leave out hypothetical ideas, jokes, things already done, offers nobody accepted, vague suggestions nobody took on, and anything cancelled later in the conversation.
    - open_questions: questions about the work that are still unanswered when the conversation ends, so someone has to answer, decide, or find out later. A question stays open when the participants only decided what to do meanwhile. Leave out questions someone answered later in the conversation, even many turns later, rhetorical questions, questions asked to start a discussion or make a point, hypothetical questions, and small talk. Write each as a full question.

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
    """# + "\n" + jsonText

    /// JSON strings and the whitespace between tokens, for both grammars.
    static let jsonText = #"""
    str ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n]{0,20}
    """#
}

private extension Notes {
    var withoutTurnIDsInText: Notes {
        var notes = self
        for i in notes.decisions.indices { notes.decisions[i].text = NotesWriter.withoutTurnIDs(notes.decisions[i].text) }
        for i in notes.actionItems.indices { notes.actionItems[i].text = NotesWriter.withoutTurnIDs(notes.actionItems[i].text) }
        for i in notes.openQuestions.indices { notes.openQuestions[i].text = NotesWriter.withoutTurnIDs(notes.openQuestions[i].text) }
        return notes
    }
}
