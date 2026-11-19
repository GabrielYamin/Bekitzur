import BekitzurDomain
import Foundation

public enum NotesWriterError: Error, CustomStringConvertible, LocalizedError {
    case unreadableOutput(String)

    public var description: String {
        switch self {
        case .unreadableOutput(let text): "The language model's Notes aren't valid JSON: \(text.prefix(200))…"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreadableOutput(let text): String(localized: "The language model's Notes aren't valid JSON: \(String(text.prefix(200)))…")
        }
    }
}

/// Writes a Conversation's Notes from its turns with a local language model.
public struct NotesWriter {
    private let model: LanguageModel

    public init(model: LanguageModel) {
        self.model = model
    }

    /// - Parameters:
    ///   - language: The conversation's.
    ///   - notesLanguage: The Notes', whatever the conversation's is.
    ///   - yourNotes: What the user wrote while recording, which adds to what was said.
    ///   - user: The user's name as the transcript has it, for their notes that say "I".
    /// - Returns: The Notes, and the draft they were checked from.
    public func write(
        turns: [Turn],
        date: Date,
        language: ConversationLanguage,
        notesLanguage: ConversationLanguage = .english,
        yourNotes: [UserNote] = [],
        user: String? = nil,
        calendar: Calendar = .current
    ) throws -> (notes: Notes, draft: Notes, completion: Completion) {
        let written = yourNotes.filter { !$0.words.isEmpty }
        let completion = try model.startChat(
            system: Self.instructions(writingIn: notesLanguage),
            user: Self.render(turns, date: date, language: language),
            grammar: Self.grammar,
            maxTokens: 6_000,
            followUp: Self.reviewTokens + Self.yourNotesTokens(written.count).room
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard var draft = try? decoder.decode(Notes.self, from: Data(completion.text.utf8)).withoutTurnIDsInText else {
            throw NotesWriterError.unreadableOutput(completion.text)
        }
        draft.language = notesLanguage
        var notes = reviewed(draft, turns: turns)
        notes = covering(written, by: user, in: notes, turns: turns, language: notesLanguage).withoutTurnIDsInText
        for i in notes.actionItems.indices {
            let due = notes.actionItems[i].duePhrase.flatMap { DueDateResolver.due($0, from: date, calendar: calendar) }
            notes.actionItems[i].dueDate = due?.date
            notes.actionItems[i].dueTime = due?.time
        }
        return (notes, draft, completion)
    }

    /// The Notes with what the user's notes add to them, asked in the same chat once they're written and checked: asked
    /// before the checks, the checks took a note for what was said and dropped a Decision it disagreed with. Given the
    /// notes with the transcript, the model took them for the outline, leaving out an item the transcript has and the
    /// owners of others; asked what they add, it copied its Notes into the reply. So it answers note by note: the item
    /// the note is the same as, and what the note says as an item. They stand as they are where the reply doesn't
    /// decode.
    private func covering(_ yourNotes: [UserNote], by user: String?, in notes: Notes, turns: [Turn], language: ConversationLanguage) -> Notes {
        guard !yourNotes.isEmpty else { return notes }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? model.continueChat(
            user: Self.yourNotesRequest(yourNotes, by: user, draft: notes, turns: turns, in: language),
            grammar: Self.yourNotesGrammar(for: yourNotes, in: notes),
            maxTokens: Self.yourNotesTokens(yourNotes.count).reply
        ),
            let checked = try? decoder.decode([CheckedNote].self, from: Data(reply.text.utf8))
        else { return notes }
        return Self.adding(checked, of: yourNotes, to: notes)
    }

    /// Room for asking about the user's notes, besides the review's: the request lists them and the Notes' items, and
    /// the reply has an item for each note.
    static func yourNotesTokens(_ count: Int) -> (reply: Int, room: Int) {
        let reply = 200 * count + 100
        return (reply, count == 0 ? 0 : 1_500 + 50 * count + reply)
    }

    /// One of the user's notes: the item it's the same as, like "A2", if any, and what it says as an item; a heading
    /// has only the item.
    struct CheckedNote: Decodable {
        let note: Int
        let sameAs: String?
        let add: Addition?
    }

    /// One of these, by what the note is.
    struct Addition: Decodable {
        let decision: Decision?
        let actionItem: ActionItem?
        let openQuestion: OpenQuestion?
        /// A sentence for the summary.
        let summary: String?

        var text: String? {
            decision?.text ?? actionItem?.text ?? openQuestion?.text ?? summary
        }
    }

    /// What was said stands: a note the same as an item gives it an Owner or a due phrase only where an action item has
    /// none, and changes nothing else; any other note adds what it says. Each item keeps which notes it has.
    static func adding(_ checked: [CheckedNote], of yourNotes: [UserNote], to draft: Notes) -> Notes {
        var notes = draft
        for entry in checked where yourNotes.indices.contains(entry.note - 1) {
            let note = yourNotes[entry.note - 1].id
            if isSame(entry, in: notes), let reference = entry.sameAs {
                link(note, to: reference, in: &notes, giving: entry.add?.actionItem)
            } else if let addition = entry.add {
                add(addition, from: note, to: &notes)
            }
        }
        return notes
    }

    /// Whether a note is the same as the item it names: the Notes have that item, and what the note says, as an item,
    /// shares two words with it. Called the same as an action item about something else, a to-do was lost. Both are in
    /// the Notes' language, whatever the note's; a heading says nothing, and goes with the item it names.
    static func isSame(_ entry: CheckedNote, in notes: Notes) -> Bool {
        guard let reference = entry.sameAs, let text = text(of: reference, in: notes) else { return false }
        guard let addition = entry.add else { return true }
        guard let written = addition.text else { return false }
        return UserNote.significantWords(written).intersection(UserNote.significantWords(text)).count >= 2
    }

    private static func text(of reference: String, in notes: Notes) -> String? {
        guard let number = Int(reference.dropFirst()), number > 0 else { return nil }
        let index = number - 1
        return switch reference.first {
        case "D": notes.decisions.indices.contains(index) ? notes.decisions[index].text : nil
        case "A": notes.actionItems.indices.contains(index) ? notes.actionItems[index].text : nil
        case "Q": notes.openQuestions.indices.contains(index) ? notes.openQuestions[index].text : nil
        default: nil
        }
    }

    private static func link(_ note: UUID, to reference: String, in notes: inout Notes, giving written: ActionItem?) {
        guard let number = Int(reference.dropFirst()), number > 0 else { return }
        let index = number - 1
        switch reference.first {
        case "D" where notes.decisions.indices.contains(index):
            notes.decisions[index].withYourNotes = (notes.decisions[index].withYourNotes ?? []) + [note]
        case "A" where notes.actionItems.indices.contains(index):
            var action = notes.actionItems[index]
            action.withYourNotes = (action.withYourNotes ?? []) + [note]
            if action.owner == nil { action.owner = given(written?.owner) }
            if action.duePhrase == nil, action.dueDate == nil { action.duePhrase = given(written?.duePhrase) }
            notes.actionItems[index] = action
        case "Q" where notes.openQuestions.indices.contains(index):
            notes.openQuestions[index].withYourNotes = (notes.openQuestions[index].withYourNotes ?? []) + [note]
        default:
            break
        }
    }

    private static func add(_ addition: Addition, from note: UUID, to notes: inout Notes) {
        if var decision = addition.decision {
            decision.fromYourNote = note
            notes.decisions.append(decision)
        }
        if var item = addition.actionItem {
            item.fromYourNote = note
            notes.actionItems.append(item)
        }
        if var question = addition.openQuestion {
            question.fromYourNote = note
            notes.openQuestions.append(question)
        }
        if let sentence = given(addition.summary) {
            notes.summary = extended(notes.summary, with: sentence)
        }
    }

    /// Text with a sentence after it.
    static func extended(_ text: String, with sentence: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return sentence }
        return (".!?".contains(last) ? trimmed : trimmed + ".") + " " + sentence
    }

    /// Text the model gave, or nil for none, which it can also write as "null".
    private static func given(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.lowercased() != "null" else { return nil }
        return text
    }

    /// The transcript shows turns, not times, so each note says which turn was being said when it was written. Action
    /// items show their Owner and due phrase, for a note to fill in only what they lack.
    static func yourNotesRequest(
        _ yourNotes: [UserNote], by user: String? = nil, draft: Notes, turns: [Turn], in language: ConversationLanguage = .english
    ) -> String {
        let notes = yourNotes.enumerated().map { offset, note in
            let during = turn(at: note.at, in: turns).map { "(during \($0)) " } ?? ""
            return "\(offset + 1). \(during)\(note.text.trimmingCharacters(in: .whitespaces))"
        }
        let decisions = draft.decisions.enumerated().map { "D\($0.offset + 1). \($0.element.text)" }
        let actionItems = draft.actionItems.enumerated().map { offset, item in
            "A\(offset + 1). \(item.text) (owner: \(item.owner ?? "none"); due: \(item.duePhrase ?? "none"))"
        }
        let questions = draft.openQuestions.enumerated().map { "Q\($0.offset + 1). \($0.element.text)" }
        let items = decisions + actionItems + questions
        let listed = items.isEmpty
            ? "Your Notes have no decisions, action items, or open questions."
            : "Your Notes have these decisions (D), action items (A), and open questions (Q):\n" + items.joined(separator: "\n")
        let who = user.map { #" The user is "\#($0)": a note that says "I" means them."# } ?? ""
        return """
        During the conversation, the user wrote notes of their own, each with the turn being said when they wrote it:
        \(notes.joined(separator: "\n"))

        \(listed)

        What was said comes first, and the notes add to it. They're short and written fast, so read each one with the turns around it.\(who) For each note in order, give:
        - same_as: your decision, action item, or open question about the same decision, task, or question as the note, like "A2", or null if none is. Another task on the same subject isn't the same task.
        - add: what the note says, the way the transcript has it and without copying the note word for word, citing the turns around the note. A decision, if the participants settled on it; an action item, if someone has to do it, with its owner's name only in the owner; an open question, if it's still unanswered when the conversation ends; otherwise, a sentence for the summary. A note that says to do something, like "[ ] send the deck" or "talk with Avi", is something the user wants done: an action item, owned by whoever the transcript or the note says will do it, \(user == nil ? "or null if nobody took it" : "otherwise by the user").
        Where a note is the same as one of your items, what was said stands: the item keeps its words and takes only an owner or a due phrase it doesn't have, and a note that says otherwise changes nothing. A heading, starting with "# ", only names what the notes after it are about: give only its same_as.

        Every field is in \(language.name).
        """
    }

    /// An entry per note in order: the item it's the same as, if any, and what it says as an item, which it adds unless
    /// it's the same. The items are the ones the Notes have, and not the summary: allowed any number, the model called a
    /// note the same as an action item the Notes didn't have, and allowed the summary, a note to talk with someone the
    /// summary never named; either way the note was lost. A to-do can only be an action item, so one isn't taken for the
    /// Decision on its subject, and a heading only goes with an item. What a note says has its turns but no quote, which
    /// greedy decoding can repeat until the reply runs out; and its text has a length, so a text repeating itself ends
    /// there instead of taking the other notes' room.
    static func yourNotesGrammar(for yourNotes: [UserNote], in notes: Notes) -> String {
        let entries = yourNotes.enumerated().map { offset, note in
            let same = switch note.kind {
            case .heading: "same-heading"
            case .task: "same-task"
            case .point: "same-any"
            }
            return #"note\#(offset + 1) ::= "{" ws "\"note\":" ws "\#(offset + 1)" "," ws "\"same_as\":" ws \#(same) ws "}""#
        }
        let root = #"root ::= "[" ws "# + yourNotes.indices.map { "note\($0 + 1)" }.joined(separator: #" "," ws "#) + #" ws "]""#
        let actions = Self.references("A", notes.actionItems.count)
        let items = actions + Self.references("D", notes.decisions.count) + Self.references("Q", notes.openQuestions.count)
        let anyItem = "(" + (items + [#""null""#]).joined(separator: " | ") + ")"
        let anAction = "(" + (actions + [#""null""#]).joined(separator: " | ") + ")"
        let choices = [
            "same-any ::= " + anyItem + #" "," ws "\"add\":" ws addition"#,
            "same-task ::= " + anAction + #" "," ws "\"add\":" ws "{" ws "\"action_item\":" ws noted-action ws "}""#,
            "same-heading ::= " + anyItem,
        ]
        let rules = choices.joined(separator: "\n") + "\n" + #"""
        addition ::= "{" ws ("\"decision\":" ws noted-decision | "\"action_item\":" ws noted-action | "\"open_question\":" ws noted-question | "\"summary\":" ws text) ws "}"
        noted-decision ::= "{" ws "\"text\":" ws text "," ws "\"source_turns\":" ws turns "," ws "\"quote\":" ws "\"\"" ws "}"
        noted-action ::= "{" ws "\"text\":" ws text "," ws "\"owner\":" ws optstr "," ws "\"due_phrase\":" ws optstr "," ws "\"source_turns\":" ws turns "," ws "\"quote\":" ws "\"\"" ws "}"
        noted-question ::= "{" ws "\"text\":" ws text "," ws "\"source_turns\":" ws turns ws "}"
        text ::= "\"" char{1,400} "\""
        """#
        return ([root] + entries + [rules, itemRules]).joined(separator: "\n")
    }

    /// The JSON strings that name a kind's items, like "A1" and "A2".
    private static func references(_ kind: String, _ count: Int) -> [String] {
        (0..<count).map { #""\"\#(kind)\#($0 + 1)\"""# }
    }

    /// The turn being said at a moment, the last one to start by then.
    static func turn(at time: Double, in turns: [Turn]) -> String? {
        turns.last { ($0.start ?? .infinity) <= time }?.id ?? turns.first { $0.start != nil }?.id
    }

    /// Room for the checks after the draft: the decisions and action items, then each open question, whose message shows
    /// up to 900 words said after it, about 4,000 tokens in Hebrew, so this covers about two of them. Checks that don't
    /// fit leave their items as drafted. More room would grow the context past its first 32K for a shorter Transcript
    /// without changing the Notes; this keeps it there up to about an hour of Hebrew.
    static let reviewTokens = 12_288

    /// The draft checked in the same chat, which still holds the transcript, since one pass over a long transcript leaves
    /// items like "We'll do it tomorrow" as they were said and lists questions that were answered later on. Decisions and
    /// action items are checked first, then each open question on its own: asked together, wording for one changes the
    /// model's answers about the other. The draft stands where the context is full or a reply doesn't decode.
    private func reviewed(_ draft: Notes, turns: [Turn]) -> Notes {
        var notes = draft
        let items = Self.reviewItems(draft)
        if !items.isEmpty,
           let reply = try? model.continueChat(user: Self.reviewRequest(items, in: draft.language ?? .english), grammar: Self.reviewGrammar(items), maxTokens: 2_000),
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

    static func reviewRequest(_ items: [ReviewItem], in language: ConversationLanguage = .english) -> String {
        func list(_ kind: ReviewItem.Kind, _ title: String) -> String? {
            let lines = items.enumerated().filter { $0.element.kind == kind }
                .map { "\($0.offset + 1). \($0.element.text) (\($0.element.sources.joined(separator: ", ")))" }
            return lines.isEmpty ? nil : "\(title):\n" + lines.joined(separator: "\n")
        }
        let lists = [list(.decision, "Decisions"), list(.actionItem, "Action items")].compactMap { $0 }
        let references = language == .hebrew ? #""זה", "את זה", "הדבר הזה""# : #""it", "this", "that""#
        return """
        Check each decision and action item of these Notes against the transcript.

        \(lists.joined(separator: "\n\n"))

        - Rewrite an item only if it says \(references), or the like instead of naming the thing. Then read the turns before its source and name what was decided or what will be done. Copy every other item exactly, and never change a name, a number, or a technical term. Every item is in \(language.name).
        - A decision the participants didn't make, like a fact, an opinion, or how things work today: null.

        Reply with every item in order: its number and its text without the turn IDs, or null.
        """
    }

    /// One open question with what was said from where it was asked on, in the message itself: Gemma's sliding-window
    /// layers see only the last 1,024 tokens, so in a later message the transcript reaches only its few global layers, and
    /// asked from there the model rarely finds an answer that comes from another speaker in other words.
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
        Language: \(language.name)

        Transcript:
        \(lines)
        """
    }

    /// The rest is the same in either language.
    static func instructions(writingIn language: ConversationLanguage) -> String {
        [role, language == .hebrew ? inHebrew : inEnglish, extraction].joined(separator: "\n\n")
    }

    private static let role = """
    You are the note-taker for a recorded work conversation. You get a transcript with numbered speaker turns like [T012]. Speakers are either named people or unnamed voices such as "Speaker 2".
    """

    private static let inEnglish = """
    Write the Notes in English, even when the conversation is in Hebrew: every field is English except "quote", which stays verbatim in the transcript's original language. Never copy a quote into another field; say in English what it means.
    """

    /// Told only to write in Hebrew, the model left out commitments it lists in English Notes, so it's told what doesn't
    /// change. Names, terms, and labels stay as the transcript writes them, since renaming a Speaker looks for their label.
    private static let inHebrew = """
    Write the Notes in Hebrew, even when the conversation is in English: every field is Hebrew except "quote", which stays verbatim in the transcript's original language. Hebrew changes only the words: extract every decision, action item, and open question you would for English Notes, with each commitment as an action item of its own. Write people's names, product names, and technical terms as the transcript writes them, English ones in English letters, and an unnamed speaker's label exactly as it is, like "Speaker 2". Keep every word in one alphabet, and join a Hebrew prefix to an English word with a hyphen, like "ב-CI". Never copy a quote into another field; say in Hebrew what it means.
    """

    private static let extraction = """
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
    """# + "\n" + itemRules

    /// The items, for the Notes and for what the user's notes add.
    private static let itemRules = #"""
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
