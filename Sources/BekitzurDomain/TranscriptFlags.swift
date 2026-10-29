import Foundation

/// What the user marked while listening back to a Transcript: words that are wrong (with what was said, if they typed
/// it), lines with the wrong Speaker, and how far they listened. Unmarked words before that point count as right,
/// which is what lets accuracy be measured on real Conversations.
public struct TranscriptFlags: Codable, Sendable, Equatable {
    /// A marked word. With a `correction`, the text was wrong; with `saidBy`, the Speaker was. With neither, the text
    /// was wrong and the user didn't say what was said. Words corrected together are one phrase: the first word's
    /// correction says what was said instead of all of them, and each of the others has an empty one.
    public struct Word: Codable, Sendable, Hashable {
        public var start: Double
        public var text: String
        public var correction: String?
        public var saidBy: String?
        /// Marked as said by someone else before the user could say who.
        public var otherSpeaker: Bool?
        /// When the phrase starts, for each word of it but the first.
        public var phrase: Double?

        /// The mark changes the Transcript: it says what was said, or who said it.
        public var isFix: Bool { correction != nil || saidBy != nil || otherSpeaker == true }
    }

    public struct Line: Codable, Sendable, Equatable {
        public var start: Double
        public var speaker: String
    }

    public var words: [Word] = []
    public var speakers: [Line] = []
    /// The furthest point the user has played to, in seconds.
    public var listenedUntil: Double = 0

    public init() {}

    /// The marks that change the Transcript, and so the Notes written from it.
    public var fixes: Set<Word> { Set(words.filter(\.isFix)) }

    public func flag(for word: TranscriptWord) -> Word? {
        index(of: word).map { words[$0] }
    }

    /// Marks the word, or takes its mark off, with the rest of the phrase it was corrected with.
    public mutating func toggle(_ word: TranscriptWord) {
        if let start = phraseStart(of: word) {
            removePhrase(startingAt: start)
        } else if let index = index(of: word) {
            words.remove(at: index)
        } else {
            words.append(Word(start: word.start, text: Self.key(word)))
        }
    }

    /// Marks the word wrong with what was said instead; an empty correction keeps it marked without one.
    public mutating func correct(_ word: TranscriptWord, as said: String) {
        correct([word], as: said)
    }

    /// What was said instead of words in a row, as one phrase. A phrase corrected before that shares a word with these
    /// is replaced whole. Typing nothing marks each word wrong.
    public mutating func correct(_ words: [TranscriptWord], as said: String) {
        guard let first = words.first else { return }
        for start in Set(words.compactMap(phraseStart(of:))) {
            removePhrase(startingAt: start)
        }
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        for (offset, word) in words.enumerated() {
            if said.isEmpty {
                setCorrection(of: word, to: nil, phrase: nil)
            } else {
                setCorrection(of: word, to: offset == 0 ? said : "", phrase: offset == 0 ? nil : first.start)
            }
        }
    }

    /// When the phrase the word was corrected with starts; nil for a word corrected on its own, or not at all.
    public func phraseStart(of word: TranscriptWord) -> Double? {
        guard let flag = flag(for: word) else { return nil }
        if let phrase = flag.phrase { return phrase }
        return words.contains { $0.phrase.map { Self.same($0, flag.start) } == true } ? flag.start : nil
    }

    /// Marks words wrong, or takes every mark off them.
    public mutating func mark(_ words: [TranscriptWord], wrong: Bool) {
        for word in words where (flag(for: word) != nil) != wrong {
            toggle(word)
        }
    }

    private mutating func removePhrase(startingAt start: Double) {
        words.removeAll { word in word.phrase.map { Self.same($0, start) } ?? Self.same(word.start, start) }
    }

    private mutating func setCorrection(of word: TranscriptWord, to correction: String?, phrase: Double?) {
        if let index = index(of: word) {
            words[index].correction = correction
            words[index].phrase = phrase
        } else {
            words.append(Word(start: word.start, text: Self.key(word), correction: correction, phrase: phrase))
        }
    }

    /// Marks the word as said by `speaker`. Choosing the Speaker it was transcribed as takes that mark off.
    public mutating func assign(_ word: TranscriptWord, to speaker: String, transcribedAs transcribed: String?) {
        let index = index(of: word)
        if speaker == transcribed {
            guard let index else { return }
            if words[index].correction == nil {
                words.remove(at: index)
            } else {
                words[index].saidBy = nil
                words[index].otherSpeaker = nil
            }
        } else if let index {
            words[index].saidBy = speaker
            words[index].otherSpeaker = nil
        } else {
            words.append(Word(start: word.start, text: Self.key(word), saidBy: speaker))
        }
    }

    /// A mark points to a word by when it starts and what speech recognition wrote, so it still finds the word after
    /// the Vocabulary rewrites it.
    private static func key(_ word: TranscriptWord) -> String {
        word.transcribed ?? word.text
    }

    private func index(of word: TranscriptWord) -> Int? {
        let key = Self.key(word)
        return words.firstIndex { Self.same($0.start, word.start) && $0.text == key }
    }

    /// Who said the word: the Speaker the user marked, or the one it was transcribed as. A word marked as said by
    /// someone else, without saying who, goes to the other Speaker when there are only two. A mark naming a Speaker
    /// the Conversation no longer has (after separating Speakers again) is ignored.
    public func speaker(of word: TranscriptWord, transcribedAs speaker: String?, among speakers: [String]) -> String? {
        guard let flag = flag(for: word) else { return speaker }
        if let saidBy = flag.saidBy, speakers.contains(saidBy) { return saidBy }
        if flag.otherSpeaker == true, let speaker {
            let others = speakers.filter { $0 != speaker }
            if others.count == 1 { return others[0] }
        }
        return speaker
    }

    /// What the word says: the user's correction, or what was transcribed.
    public func text(of word: TranscriptWord) -> String {
        flag(for: word)?.correction ?? word.text
    }

    public func isSpeakerFlagged(lineStartingAt start: Double) -> Bool {
        speakers.contains { Self.same($0.start, start) }
    }

    public mutating func toggleSpeaker(lineStartingAt start: Double, speaker: String) {
        if let index = speakers.firstIndex(where: { Self.same($0.start, start) }) {
            speakers.remove(at: index)
        } else {
            speakers.append(Line(start: start, speaker: speaker))
        }
    }

    private static func same(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.005
    }
}
