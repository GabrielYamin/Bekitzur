import BekitzurDomain
import Foundation

/// Answers questions about one Conversation from its transcript alone, as a chat that keeps the transcript in the
/// language model's context, so a follow-up question costs only its own words. A chat that starts over is given the
/// earlier questions with the answers the user saw, so a follow-up still has what it refers to.
///
/// The model gives its evidence before its answer: turns of the transcript, each with an exact quote. The quotes are
/// checked against those turns, and without one that checks out the answer is that the Conversation doesn't say,
/// whatever the model wrote. The model is told to give no evidence when the transcript doesn't answer the question.
public final class ConversationQuestions {
    private let model: LanguageModel
    public let turns: [Turn]
    private let date: Date
    private let language: ConversationLanguage
    private var chatting = false
    /// The last answer the user saw was that the Conversation doesn't say, which the model's own reply in the chat may
    /// not show.
    private var lastNotFound = false
    /// The model's last reply, before its quotes were checked.
    public private(set) var lastReply = ""

    public init(model: LanguageModel, turns: [Turn], date: Date, language: ConversationLanguage) {
        self.model = model
        self.turns = turns
        self.date = date
        self.language = language
    }

    /// - Parameter earlier: Questions already answered about this Conversation, with the answers the user was shown; a
    ///   chat that starts over is given the last of them.
    public func ask(_ question: String, after earlier: [(question: String, answer: Answer)] = []) throws -> Answer {
        let message = """
        Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        Answer in the language this question is written in; terms it borrows from another language don't change that.
        """
        var completion: Completion?
        if chatting {
            do {
                let note = lastNotFound ? Self.notFoundNote + "\n\n" : ""
                completion = try model.continueChat(user: note + message, grammar: Self.grammar, maxTokens: 1_000)
            } catch LanguageModelError.promptTooLong {
                // The context is full of earlier questions: start over with the transcript.
            }
        }
        if completion == nil {
            completion = try start(message, after: earlier)
            chatting = true
        }
        lastReply = completion?.text ?? ""
        var answer = Self.answer(from: lastReply, turns: turns)
        if answer.text == nil, let second = try? model.continueChat(user: Self.lookAgain, grammar: Self.grammar, maxTokens: 1_000) {
            lastReply = second.text
            answer = Self.answer(from: second.text, turns: turns)
        }
        lastNotFound = answer.text == nil
        return answer
    }

    /// Asked when nothing answered the question as it was put. Told in one message to answer what the question means, the
    /// model still gave nothing for "What feature is the design doc for?" where no feature is named but the design
    /// document is described; asked to look again, it can say what the transcript does say.
    static let lookAgain = """
    Nothing in the transcript answers that as asked. Look again for what the question means, which may be called \
    something else there, or not be what the question takes for granted: a design document asked about as a PoC, or a \
    plan asked about by a feature it never names. Speech recognition can also write a term from another language in \
    the conversation's alphabet, or run it together with a word ending of the conversation's language. If the \
    transcript talks about it, quote those turns and answer with what they say, starting with what they don't say, \
    like "No feature is named; …". If it doesn't talk about it at all, give no evidence and an empty answer again.
    """

    private func start(_ message: String, after earlier: [(question: String, answer: Answer)]) throws -> Completion {
        let transcript = NotesWriter.render(turns, date: date, language: language)
        let history = Self.history(earlier)
        do {
            return try model.startChat(system: Self.instructions(for: language), user: transcript + history + "\n\n" + message, grammar: Self.grammar, maxTokens: 1_000)
        } catch LanguageModelError.promptTooLong where !history.isEmpty {
            // A Conversation too long for its earlier questions still gets an answer.
            return try model.startChat(system: Self.instructions(for: language), user: transcript + "\n\n" + message, grammar: Self.grammar, maxTokens: 1_000)
        }
    }

    /// The last questions answered, each with the answer the user was shown and the turns it quoted.
    static func history(_ earlier: [(question: String, answer: Answer)], keeping count: Int = 10) -> String {
        guard !earlier.isEmpty else { return "" }
        let exchanges = earlier.suffix(count).map { exchange in
            guard let text = exchange.answer.text else {
                return "- Q: \(exchange.question)\n  A: The transcript doesn't say."
            }
            var quoted: [String] = []
            for evidence in exchange.answer.evidence where !quoted.contains(evidence.turn) {
                quoted.append(evidence.turn)
            }
            return "- Q: \(exchange.question)\n  A: \(text) (\(quoted.joined(separator: ", ")))"
        }
        return "\n\nEarlier questions about this conversation, with the answers I was given:\n" + exchanges.joined(separator: "\n")
    }

    static let notFoundNote = "I was told the transcript doesn't answer my last question."

    /// The model's reply as an Answer, keeping only evidence whose quote is in its turn: at least two words, compared
    /// without case, punctuation, or spacing.
    static func answer(from reply: String, turns: [Turn]) -> Answer {
        struct Reply: Decodable {
            let evidence: [Evidence]
            let answer: String
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(reply.utf8)) else { return .notInConversation }
        let turnWithID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let checked = reply.evidence.compactMap { evidence -> Evidence? in
            let quote = normalized(evidence.quote)
            guard quote.split(separator: " ").count >= 2, let turn = turnWithID[evidence.turn], normalized(turn.text).contains(quote) else { return nil }
            return Evidence(turn: turn.id, quote: evidence.quote, speaker: turn.speaker, start: turn.start)
        }
        // The quotes show which turns an answer comes from, so turn numbers the model writes into it go.
        let text = reply.answer.replacing(/\s*[\[(]T\d+(?:\s*[,–-]\s*T?\d+)*[\])]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !checked.isEmpty, !text.isEmpty else { return .notInConversation }
        return Answer(text: text, evidence: checked)
    }

    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The conversation's language is named: told only that a question can be in another language than the
    /// conversation's, the model answered most English questions about a Hebrew conversation in Hebrew.
    static func instructions(for language: ConversationLanguage) -> String {
        let spoken = language.name
        return """
        You answer questions about one recorded work conversation, using only its transcript, which has numbered speaker \
        turns like [T012]. Speakers are named people or unnamed voices like "Speaker 2". The conversation is in \
        \(spoken), and a question can be in another language: find what it asks about in the \(spoken), where it may be \
        said in \(spoken) words or in the question's terms written in \(spoken) letters.

        For each question, first give the evidence: the turns that answer it, each with an exact quote of at least a few \
        words, copied character for character from that turn. Then give a short answer in the language of the question, \
        saying who said what when that matters.

        A question can call something by another name than the transcript does, or take for granted something it \
        doesn't say: ask about a PoC when only a design document came up, which feature a plan is for when no feature is \
        named, or why someone did something they didn't do. Then answer with what the transcript does say about what the \
        question means, and say first what it doesn't say, like "No feature is named; …" or "Nobody rejected it; …" in \
        the question's language. Never take on what the question takes for granted unless the transcript says it.

        If the transcript says nothing about what the question is about, give no evidence and an empty answer. Never \
        guess, never fill a gap with what usually happens or what you know from elsewhere, and answer from nothing but \
        the transcript.

        A question may follow earlier ones, asked before in this chat or listed after the transcript with the answers \
        given. Use them to tell what the question refers to, like who "he" is; they aren't evidence, so quote only the \
        transcript's turns.
        """
    }

    /// The evidence, at most five quotes, then the answer.
    static let grammar = #"""
    root ::= "{" ws "\"evidence\":" ws evidence "," ws "\"answer\":" ws str ws "}"
    evidence ::= "[" ws "]" | "[" ws item ("," ws item){0,4} ws "]"
    item ::= "{" ws "\"turn\":" ws turn "," ws "\"quote\":" ws str ws "}"
    turn ::= "\"T" [0-9] [0-9] [0-9] [0-9]? "\""
    str ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n]{0,20}
    """#
}
