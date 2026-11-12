import BekitzurDomain
import Foundation

/// A chat about one Conversation: its transcript, kept in the language model's context so a follow-up costs only its own
/// words, and its Notes, which the chat changes when a message asks it to. A chat that starts over is given the earlier
/// messages with the answers the user saw.
///
/// The model says whether the message asks for a change, gives its changes to the Notes if it does, then its evidence:
/// turns of the transcript, each with an exact quote, or Notes items. The quotes are checked against those turns. A
/// reply that changes nothing and has no evidence that checks out is that the Conversation doesn't say, whatever the
/// model wrote; the model is told to give no evidence when nothing answers. With the evidence before the changes, the
/// model made none when a chat's first message asked for an item that no turn talks about.
public final class ConversationChat {
    private let model: LanguageModel
    public let turns: [Turn]
    private let date: Date
    private let language: ConversationLanguage
    private var chatting = false
    /// The last answer the user saw was that the Conversation doesn't say, which the model's own reply in the chat may
    /// not show.
    private var lastNotFound = false
    /// The Notes as the model last saw them, with its own changes, and what its last reply changed: the next message
    /// shows the Notes again when it changed them or something else did, since the model doesn't work out the names its
    /// changes left. Told nothing after adding an item, it took "change its owner" for the first one.
    private var notesSeen: Notes?
    private var lastEdits: [AppliedEdit] = []
    /// The model's last reply, before its quotes were checked, with its second look when it had one.
    public private(set) var lastReply = ""

    /// Room for the chat after the transcript, which the context can't grow for once the chat has started; a chat that
    /// fills it starts over, reading the transcript again.
    static let room = 16_384
    static let replyTokens = 1_500

    public init(model: LanguageModel, turns: [Turn], date: Date, language: ConversationLanguage) {
        self.model = model
        self.turns = turns
        self.date = date
        self.language = language
    }

    /// - Parameters:
    ///   - notes: The Notes as they are now.
    ///   - earlier: Messages already sent about this Conversation, with the changes and answers the user was shown; a
    ///     chat that starts over is given the last of them.
    ///   - today: When the message is sent, which a due phrase said only in the chat counts from.
    public func send(_ message: String, notes: Notes, after earlier: [ChatExchange] = [], today: Date = Date()) throws -> ChatReply {
        let request = Self.request(message, notesIn: notes.language ?? .english)
        var completion: Completion?
        if chatting {
            var update = lastNotFound ? Self.notFoundNote + "\n\n" : ""
            if notes != notesSeen || !lastEdits.isEmpty {
                update += "The Notes now:\n" + Self.listing(notes) + "\n\n" + Self.lastChange(lastEdits, in: notes)
            }
            do {
                completion = try model.continueChat(user: update + request, grammar: Self.grammar, maxTokens: Self.replyTokens)
            } catch LanguageModelError.promptTooLong {
                // The chat filled the room left after the transcript: start over with it.
            }
        }
        if completion == nil {
            completion = try start(request, notes: notes, after: earlier)
            chatting = true
        }
        notesSeen = notes
        var used = completion?.text ?? ""
        lastReply = used
        let due = { [turns, date] (phrase: String) in Self.due(phrase, saidIn: turns, on: date, today: today) }
        var reply = Self.reply(from: used, turns: turns, notes: notes, due: due)
        if reply.answer.text == nil, reply.edits.isEmpty,
           let second = try? model.continueChat(user: Self.lookAgain, grammar: Self.answerGrammar, maxTokens: Self.replyTokens) {
            used = second.text
            lastReply += "\n\nLooked again:\n" + used
            reply = Self.reply(from: used, turns: turns, notes: notes, due: due)
        }
        if let changed = reply.notes { notesSeen = changed }
        lastEdits = reply.edits
        lastNotFound = reply.answer.text == nil && reply.edits.isEmpty
        return ChatReply(answer: reply.answer, notes: reply.notes, edits: reply.edits, raw: used)
    }

    /// A message as the chat sends it. Told only which language to answer in, the model wrote a summary asked for in
    /// Hebrew in Hebrew, and its answer in the English of the Notes.
    static func request(_ message: String, notesIn language: ConversationLanguage) -> String {
        """
        Message: \(message.trimmingCharacters(in: .whitespacesAndNewlines))
        Answer in \(Self.language(of: message).name), and write anything you put in the Notes in \(language.name).
        """
    }

    /// Asked when nothing answered the message as it was put. Told in one message to answer what the question means, the
    /// model can still give nothing for a question that takes for granted what the transcript doesn't say; asked to look
    /// again, it can say what the transcript does say.
    static let lookAgain = """
    Nothing in the transcript answers that as asked. Look again for what the question means, which may be called \
    something else there, or not be what the question takes for granted: a design document asked about as a PoC, or a \
    plan asked about by a feature it never names. Speech recognition can also write a term from another language in \
    the conversation's alphabet, or run it together with a word ending of the conversation's language. If the \
    transcript talks about it, quote those turns and answer with what they say, starting with what they don't say, \
    like "No feature is named; …". If it doesn't talk about it at all, give no evidence and an empty answer again.
    """

    private func start(_ request: String, notes: Notes, after earlier: [ChatExchange]) throws -> Completion {
        let transcript = NotesWriter.render(turns, date: date, language: language)
        let system = Self.instructions(for: language, notesIn: notes.language ?? .english)
        do {
            return try model.startChat(
                system: system, turns: Self.opening(transcript, notes: notes, after: earlier, request: request), grammar: Self.grammar,
                maxTokens: Self.replyTokens, followUp: Self.room
            )
        } catch LanguageModelError.promptTooLong where !earlier.isEmpty {
            // A Conversation too long for its earlier messages still gets an answer.
            return try model.startChat(
                system: system, turns: Self.opening(transcript, notes: notes, after: [], request: request), grammar: Self.grammar,
                maxTokens: Self.replyTokens, followUp: Self.room
            )
        }
    }

    /// The turns a chat starts with: the transcript, the Notes, and the earlier messages, then the new one. The last
    /// message that was replied to comes back as it went, its reply as the model's own, so that a message pointing at
    /// what it changed reads as in a chat that never stopped: given only as one of the earlier messages, "remove it"
    /// after "change its owner" read as a question about the meeting.
    static func opening(_ transcript: String, notes: Notes, after earlier: [ChatExchange], request: String) -> [String] {
        let replied = earlier.filter { $0.answer != nil && $0.failure == nil }
        guard let last = replied.last, let reply = last.reply else {
            return [transcript + "\n\nThe Notes Bekitzur wrote from it:\n" + listing(notes) + history(replied, in: notes) + "\n\n" + request]
        }
        let seen = last.notesBefore ?? notes
        let first = transcript + "\n\nThe Notes Bekitzur wrote from it:\n" + listing(seen) + history(Array(replied.dropLast()), in: seen)
            + "\n\n" + Self.request(last.message, notesIn: seen.language ?? .english)
        var next = ""
        if last.answer?.text == nil, last.edits.isEmpty { next += notFoundNote + "\n\n" }
        if notes != (last.notesAfter ?? seen) || !last.edits.isEmpty {
            next += "The Notes now:\n" + listing(notes) + "\n\n" + (last.undone ? "" : lastChange(last.edits, in: notes))
        }
        return [first, reply, next + request]
    }

    /// What the last reply changed, by the names the Notes give it now. With only the Notes before it, "remove it"
    /// after a change took their last item.
    static func lastChange(_ edits: [AppliedEdit], in notes: Notes) -> String {
        var changed: [String] = []
        for edit in edits {
            let part: String? = switch edit.kind {
            case .title: "the title"
            case .summary: "the summary"
            case .added, .changed: notes.name(of: edit)
            case .removed: nil
            }
            if let part, !changed.contains(part) { changed.append(part) }
        }
        return changed.isEmpty ? "" : "Your last reply changed \(changed.joined(separator: ", ")).\n\n"
    }

    /// Hebrew when at least as many of the message's words have a Hebrew letter as are written in another alphabet,
    /// since Hebrew messages borrow English terms. Told to answer in the message's language, the model answered some
    /// English messages in Arabic once a reply's edits and evidence came first.
    static func language(of message: String) -> ConversationLanguage {
        var hebrew = 0
        var other = 0
        for word in message.split(whereSeparator: \.isWhitespace) {
            if word.unicodeScalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) {
                hebrew += 1
            } else if word.contains(where: \.isLetter) {
                other += 1
            }
        }
        return hebrew > 0 && hebrew >= other ? .hebrew : .english
    }

    /// A due phrase said in the conversation counts from its date; one said only in the chat, from the day it's said.
    static func due(_ phrase: String, saidIn turns: [Turn], on date: Date, today: Date, calendar: Calendar = .current) -> (date: String, time: String?)? {
        let said = normalized(phrase)
        let fromConversation = !said.isEmpty && turns.contains { normalized($0.text).contains(said) }
        return DueDateResolver.due(phrase, from: fromConversation ? date : today, calendar: calendar)
    }

    /// The Notes as the chat reads them, each item named by its place: D1, A1, Q1.
    static func listing(_ notes: Notes) -> String {
        var lines = ["Title: \(notes.title)", "Summary: \(notes.summary)"]
        lines.append(notes.decisions.isEmpty ? "Decisions: none" : "Decisions:")
        for (index, decision) in notes.decisions.enumerated() { lines.append("D\(index + 1). \(decision.text)") }
        lines.append(notes.actionItems.isEmpty ? "Action items: none" : "Action items:")
        for (index, item) in notes.actionItems.enumerated() {
            var details: [String] = []
            if let owner = item.owner { details.append("owner: \(owner)") }
            if let dueDate = item.dueDate {
                details.append("due: " + ([dueDate, item.dueTime].compactMap(\.self).joined(separator: " ")))
            } else if let phrase = item.duePhrase {
                details.append("due: \"\(phrase)\"")
            }
            if item.done == true { details.append("done") }
            lines.append("A\(index + 1). \(item.text)" + (details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"))
        }
        lines.append(notes.openQuestions.isEmpty ? "Open questions: none" : "Open questions:")
        for (index, question) in notes.openQuestions.enumerated() { lines.append("Q\(index + 1). \(question.text)") }
        return lines.joined(separator: "\n")
    }

    /// The last messages that were replied to, each with the answer the user was shown, the turns it quoted, and the
    /// items it added or changed as `notes` name them now. The answer says what a reply changed: listed apart as well, a
    /// change to the summary kept the model from changing it again after the chat started over.
    static func history(_ earlier: [ChatExchange], in notes: Notes, keeping count: Int = 10) -> String {
        let replied = earlier.filter { $0.answer != nil && $0.failure == nil }
        guard !replied.isEmpty else { return "" }
        let exchanges = replied.suffix(count).map { exchange in
            var named: [String] = []
            for evidence in exchange.answer?.evidence ?? [] where !named.contains(evidence.turn) {
                named.append(evidence.turn)
            }
            for edit in exchange.edits where !exchange.undone {
                if let item = notes.name(of: edit), !named.contains(item) { named.append(item) }
            }
            var answer = exchange.answer?.text ?? (exchange.edits.isEmpty ? "The transcript doesn't say." : "Changed the Notes.")
            if !named.isEmpty { answer += " (\(named.joined(separator: ", ")))" }
            if exchange.undone { answer += " I undid that change." }
            return "- Message: \(exchange.message)\n  Answer: \(answer)"
        }
        return "\n\nEarlier messages about this conversation, with the answers I was given:\n" + exchanges.joined(separator: "\n")
    }

    static let notFoundNote = "I was told the transcript doesn't answer my last message."

    /// The model's reply as the chat's: its edits made to `notes`, and its answer with only the evidence that checks
    /// out, a quote of the turn it cites, shown in the turn's words, or a Notes item `notes` has. A reply that changes
    /// nothing needs some evidence and an answer.
    static func reply(from text: String, turns: [Turn], notes: Notes, due: (String) -> (date: String, time: String?)?) -> ChatReply {
        guard let separator = text.range(of: "\nAnswer:"),
              let reply = try? JSONDecoder().decode(ModelReply.self, from: Data(text[..<separator.lowerBound].utf8)) else {
            return ChatReply(answer: .notInConversation)
        }
        let turnWithID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var checked: [Evidence] = []
        var citesNotes = false
        for cited in reply.evidence {
            if let item = cited.item {
                citesNotes = citesNotes || notes.place(of: item) != nil
                continue
            }
            guard let id = cited.turn, let quote = cited.quote, let turn = turnWithID[id],
                  let said = words(quotedBy: quote, in: turn.text) else { continue }
            checked.append(Evidence(turn: turn.id, quote: said, speaker: turn.speaker, start: turn.start))
        }
        // The quotes show which turns an answer comes from, so turn numbers the model writes into it go.
        let answer = text[separator.upperBound...].replacing(/(?:\s+(?:in|at|from|see))?\s*[\[(]T\d+(?:\s*[,–-]\s*T?\d+)*[\])]/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (changed, applied) = notes.applying(reply.edits.compactMap(\.edit), due: due)
        if !applied.isEmpty {
            return ChatReply(answer: Answer(text: answer.isEmpty ? nil : answer, evidence: checked), notes: changed, edits: applied)
        }
        guard checked.count + (citesNotes ? 1 : 0) > 0, !answer.isEmpty else { return ChatReply(answer: .notInConversation) }
        return ChatReply(answer: Answer(text: answer, evidence: checked))
    }

    /// The words of `text` that `quote` quotes, compared without case or punctuation; nil when it doesn't quote them.
    /// The model now and then leaves out a small word ("לי") or miscopies a letter ("רגלי" for "רגעי"), so a quote can
    /// differ from the turn's words by a word in four, at most three: a word of the turn left out, a word of the quote
    /// that isn't there, or a word in place of another. Under four words, it has to be exact.
    static func words(quotedBy quote: String, in text: String) -> String? {
        let said = normalized(quote).split(separator: " ")
        guard said.count >= 2 else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var words: [(word: Substring, token: Int)] = []
        for (index, token) in tokens.enumerated() {
            for word in normalized(String(token)).split(separator: " ") { words.append((word, index)) }
        }
        guard !words.isEmpty else { return nil }
        // Differences between the quote's first i words and turn words that end at the j-th, with where they start:
        // turn words before the quote begins and after it ends are free.
        var previous = (0...words.count).map { (differences: 0, start: $0) }
        for i in 1...said.count {
            var row = [(differences: i, start: 0)]
            for j in 1...words.count {
                let cost = said[i - 1] == words[j - 1].word ? 0 : 1
                let replaced = (differences: previous[j - 1].differences + cost, start: previous[j - 1].start)
                let missing = (differences: previous[j].differences + 1, start: previous[j].start)
                let skipped = (differences: row[j - 1].differences + 1, start: row[j - 1].start)
                row.append([replaced, missing, skipped].min { $0.differences < $1.differences }!)
            }
            previous = row
        }
        // Of equally close matches, the one that reaches furthest: a last word miscopied is a word of the turn.
        var best = (differences: Int.max, start: 0, end: 0)
        for j in 1...words.count where previous[j].differences <= best.differences {
            best = (previous[j].differences, previous[j].start, j - 1)
        }
        guard best.differences <= min(3, said.count / 4), best.start <= best.end else { return nil }
        return tokens[words[best.start].token...words[best.end].token].joined(separator: " ")
    }

    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The conversation's language is named: told only that a message can be in another language than the
    /// conversation's, the model answers most English questions about a Hebrew conversation in Hebrew.
    static func instructions(for language: ConversationLanguage, notesIn notesLanguage: ConversationLanguage) -> String {
        let spoken = language.name
        return """
        You chat with the user about one recorded work conversation: its transcript, which has numbered speaker turns \
        like [T012], and the Notes Bekitzur wrote from it, whose items are numbered D1, D2… for decisions, A1, A2… for \
        action items, and Q1, Q2… for open questions; an action item is done only when it says "done". Speakers are \
        named people or unnamed voices like "Speaker 2". The \
        conversation is in \(spoken), and a message can be in another language: find what it asks about in the \
        \(spoken), where it may be said in \(spoken) words or in the message's terms written in \(spoken) letters.

        For each message, first say what it asks: "change" when it asks you to add to the Notes, change them, or remove \
        something from them, even put as a question ("Can you add…?"), and "question" for anything else, which changes \
        nothing. Then give your edits to the Notes, if it asks for any. Then give the evidence: the turns that \
        answer it, each with an exact quote of at least a few words, copied character for character from that turn, or \
        the Notes items it's about. Then give a short answer in the language of the message, saying who said what when \
        that matters. The user sees the quotes but no turn or item numbers, so the answer never mentions them: it calls \
        an item by what it says.

        Change the Notes only when the message asks you to add to them, change them, or remove something from them; a \
        question about them changes nothing. Make the changes such a message asks for even when the transcript never \
        mentions what they add, since the user decides what goes in their Notes, and give as evidence only the turns or \
        items they're about, if any. In edits and evidence, name items by their numbers in the Notes as you last saw \
        them. An edit is:
        - add: a new decision, action_item, or open_question, with its text, its owner (a name, or a speaker's label \
        exactly as the transcript writes it), and when it's due in words ("tomorrow at 4pm", "עד יום חמישי"), or null.
        - change: an item's new text, owner, or due, or whether an action item is done; null keeps a field as it is, and \
        an empty string takes an owner or a due off.
        - remove: an item.
        - title: the Notes' new title, when the message asks to rename them.
        - summary: the Notes' new summary, written out in full, when the message asks to change the summary.
        Write new and changed text in \(notesLanguage.name), keeping names, terms, and labels as the transcript writes \
        them. The answer then says what you changed, like "Added an action item for Dana to review the plan by Monday."

        A question can call something by another name than the transcript does, or take for granted something it \
        doesn't say: ask about a PoC when only a design document came up, which feature a plan is for when no feature is \
        named, or why someone did something they didn't do. Then answer with what the transcript does say about what the \
        question means, and say first what it doesn't say, like "No feature is named; …" or "Nobody rejected it; …" in \
        the message's language. Never take on what a question takes for granted unless the transcript says it.

        If neither the transcript nor the Notes say anything about what a question is about, give no evidence, no edits, \
        and an empty answer. Never guess, never fill a gap with what usually happens or what you know from elsewhere, \
        and answer from nothing but the transcript and the Notes. That's for questions: a message that asks to change \
        the Notes gets its changes.

        A message may follow earlier ones, sent before in this chat or listed after the Notes with the answers given. \
        Use them to tell what it refers to, like who "he" is; they aren't evidence, so quote only the transcript's turns.
        """
    }

    /// Whether the message asks for a change, then at most ten edits when it does, and at most five pieces of evidence,
    /// then the answer, written as it is rather than as a JSON string: there, the model ended an answer with the
    /// quotation mark it opened to quote a Notes item. Without saying first what the message asks, the model changed
    /// an Action Item for a question, after the chat started over.
    static let grammar = #"""
    root ::= "{" ws "\"asks\":" ws asks "," ws "\"evidence\":" ws evidence ws "}\nAnswer:" answer
    asks ::= "\"question\"," ws "\"edits\":" ws "[" ws "]" | "\"change\"," ws "\"edits\":" ws edits
    answer ::= (" " [^\x00-\x09\x0B-\x1F\x7F]*)?
    evidence ::= "[" ws "]" | "[" ws cited ("," ws cited){0,4} ws "]"
    cited ::= quoted | noted
    quoted ::= "{" ws "\"turn\":" ws turn "," ws "\"quote\":" ws str ws "}"
    noted ::= "{" ws "\"item\":" ws item ws "}"
    edits ::= "[" ws "]" | "[" ws edit ("," ws edit){0,9} ws "]"
    edit ::= add | change | remove | title | summary
    add ::= "{" ws "\"add\":" ws section "," ws "\"text\":" ws str "," ws "\"owner\":" ws optstr "," ws "\"due\":" ws optstr ws "}"
    change ::= "{" ws "\"change\":" ws item "," ws "\"text\":" ws optstr "," ws "\"owner\":" ws optstr "," ws "\"due\":" ws optstr "," ws "\"done\":" ws optbool ws "}"
    remove ::= "{" ws "\"remove\":" ws item ws "}"
    title ::= "{" ws "\"title\":" ws str ws "}"
    summary ::= "{" ws "\"summary\":" ws str ws "}"
    section ::= "\"decision\"" | "\"action_item\"" | "\"open_question\""
    item ::= "\"" [DAQ] [1-9] [0-9]? "\""
    turn ::= "\"T" [0-9] [0-9] [0-9] [0-9]? "\""
    optstr ::= str | "null"
    optbool ::= "true" | "false" | "null"
    str ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n]{0,20}
    """#

    /// For a second look at a message nothing answered, which asks for an answer and so changes nothing.
    static let answerGrammar = grammar.replacing(#" | "\"change\"," ws "\"edits\":" ws edits"#, with: "")

    private struct ModelReply: Decodable {
        struct Cited: Decodable {
            let turn: String?
            let quote: String?
            let item: String?
        }

        let evidence: [Cited]
        let edits: [ModelEdit]
    }

    /// An edit as the grammar writes it, named by its first key; nil for one the Notes can't take.
    private struct ModelEdit: Decodable {
        let edit: NotesEdit?

        private enum Key: String, CodingKey {
            case add, change, remove, title, summary, text, owner, due, done
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            let text = try values.decodeIfPresent(String.self, forKey: .text)
            let owner = try values.decodeIfPresent(String.self, forKey: .owner)
            let due = try values.decodeIfPresent(String.self, forKey: .due)
            if let section = try values.decodeIfPresent(String.self, forKey: .add) {
                edit = NotesEdit.Section(rawValue: section).map { NotesEdit.add($0, text: text ?? "", owner: owner, due: due) }
            } else if let item = try values.decodeIfPresent(String.self, forKey: .change) {
                edit = .change(item: item, text: text, owner: owner, due: due, done: try values.decodeIfPresent(Bool.self, forKey: .done))
            } else if let item = try values.decodeIfPresent(String.self, forKey: .remove) {
                edit = .remove(item: item)
            } else if let title = try values.decodeIfPresent(String.self, forKey: .title) {
                edit = .title(title)
            } else if let summary = try values.decodeIfPresent(String.self, forKey: .summary) {
                edit = .summary(summary)
            } else {
                edit = nil
            }
        }
    }
}
