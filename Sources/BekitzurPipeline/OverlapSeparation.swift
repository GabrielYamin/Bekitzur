import BekitzurDomain
import BekitzurSpeakers
import Foundation

/// Where people on the same side talk at once, the words of each: the voices separated (`VoiceSeparator`), each
/// transcribed on its own, and merged into the Transcript. Speech recognition writes one stream of words per input, so
/// there the quieter person's words are lost or go to the louder one; the timeline model hears both, but its turns can
/// only say whose a word is, not bring back a lost one.
///
/// Separation decides only the moments the timeline hears two voices of an input at once: one after the other, two
/// people can come out in the same separated voice, and who's talking is already known there.
public enum OverlapSeparation {
    /// What separating needs from the app: the model, and transcription as the app runs it.
    public struct Resources: Sendable {
        public let package: URL
        public let compiled: URL
        public let transcribe: @Sendable ([Float], ConversationLanguage) async throws -> Transcript
        public let log: @Sendable (String) -> Void

        public init(
            package: URL,
            compiled: URL,
            transcribe: @escaping @Sendable ([Float], ConversationLanguage) async throws -> Transcript,
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.package = package
            self.compiled = compiled
            self.transcribe = transcribe
            self.log = log
        }
    }

    struct Stretch: Equatable {
        var start: Double
        var end: Double
        let input: RecordingInput?
    }

    /// A word speech recognition wrote in one separated voice, and how sure it was of the phrase it's in.
    struct Found {
        let word: TranscriptWord
        let speaker: String
        let voice: String
        let input: RecordingInput?
        let confidence: Float
    }

    static let frame = 0.01
    /// Kept on each side of a moment of two at once, which both the model and speech recognition need.
    static let context = 1.0
    /// How near a moment of two at once a word must be for separation to decide whose it is.
    static let margin = 0.2
    /// The average probability of a phrase in a separated voice below which its new words are left out: over a
    /// separated voice's sounds that aren't words, speech recognition writes some anyway, unsure of them.
    static let confidence: Float = 0.55
    /// The pause that ends a phrase.
    static let pause = 1.0
    /// Silence between the pieces of one voice transcribed together.
    static let gap = 1.5

    /// The Transcript's segments with the words of people who talked at once each given to its own voice, and the words
    /// only separation heard added, marked `separated`.
    /// - Parameter audio: The 16 kHz mono audio of an input, or of the whole Recording for nil.
    public static func apply(
        to segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        speakers: [Speaker],
        language: ConversationLanguage,
        length: Double,
        audio: (RecordingInput?) -> [Float],
        resources: Resources
    ) async throws -> [TranscriptSegment] {
        let activity = Activity(turns, length: length)
        let moments = activity.moments()
        let windows = windows(around: moments)
        guard !windows.isEmpty else { return segments }
        let started = Date()
        let separator = try await VoiceSeparator(package: resources.package, compiled: resources.compiled)
        let names = Dictionary(speakers.map { ($0.voice, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        // A separated voice can go from one person to another within a window, as one stops and another starts, so
        // it's named moment by moment.
        var pieces: [[(window: Stretch, samples: [Float])]] = [[], []]
        var namings: [[(moment: Stretch, voices: [String])]] = []
        for window in windows {
            let track = audio(window.input)
            let from = min(track.count, Int(window.start * 16_000)), to = min(track.count, Int(window.end * 16_000))
            guard to - from > 1_600 else { continue }
            let separated = try separator.separate(Array(track[from..<to]))
            guard separated.count == 2 else { continue }
            let inside = moments.filter { $0.input == window.input && $0.start >= window.start && $0.end <= window.end }
            namings.append(inside.map { ($0, activity.voices(of: separated, at: $0, in: window)) })
            for k in 0..<2 { pieces[k].append((window, separated[k])) }
        }
        let separating = Date().timeIntervalSince(started)
        var found: [Found] = []
        for k in 0..<2 {
            for item in try await transcribed(pieces[k], language: language, transcribe: resources.transcribe) {
                let time = moment(of: item.word)
                func distance(_ moment: Stretch) -> Double { max(0, moment.start - time, time - moment.end) }
                guard let nearest = namings[item.piece].min(by: { distance($0.moment) < distance($1.moment) }), nearest.voices.count == 2,
                      let speaker = names[nearest.voices[k]] else { continue }
                found.append(Found(word: item.word, speaker: speaker, voice: nearest.voices[k], input: nearest.moment.input, confidence: item.confidence))
            }
        }
        let merged = merge(segments, found: found, activity: activity)
        resources.log(String(format: "Separated %d stretches where people talked at once (%.0f s) in %.1f s and transcribed them in %.1f s: %d words given to another Speaker, %d added",
                             windows.count, windows.reduce(0) { $0 + $1.end - $1.start }, separating, Date().timeIntervalSince(started) - separating, merged.moved, merged.added))
        return merged.segments
    }

    /// The moments widened by `context` on each side, joined where they meet, input by input.
    static func windows(around moments: [Stretch]) -> [Stretch] {
        var windows: [Stretch] = []
        for moment in moments.sorted(by: { $0.start < $1.start }) {
            let widened = Stretch(start: max(0, moment.start - context), end: moment.end + context, input: moment.input)
            if let last = windows.lastIndex(where: { $0.input == moment.input }), widened.start <= windows[last].end {
                windows[last].end = max(windows[last].end, widened.end)
            } else {
                windows.append(widened)
            }
        }
        return windows
    }

    /// One separated voice's pieces transcribed together, a silence between them and each as loud as the others: each
    /// word back at its place in the Recording, with its piece and how sure speech recognition was of its phrase.
    static func transcribed(
        _ pieces: [(window: Stretch, samples: [Float])],
        language: ConversationLanguage,
        transcribe: @Sendable ([Float], ConversationLanguage) async throws -> Transcript
    ) async throws -> [(word: TranscriptWord, piece: Int, confidence: Float)] {
        guard !pieces.isEmpty else { return [] }
        let silence = [Float](repeating: 0, count: Int(gap * 16_000))
        var joined: [Float] = []
        var offsets: [(start: Double, end: Double, window: Stretch)] = []
        for piece in pieces {
            let start = Double(joined.count) / 16_000
            let peak = piece.samples.reduce(Float(0)) { max($0, abs($1)) }
            joined += piece.samples.map { $0 * 0.9 / max(peak, 1e-6) }
            offsets.append((start, Double(joined.count) / 16_000, piece.window))
            joined += silence
        }
        let words = try await transcribe(joined, language).segments.flatMap { $0.words ?? [] }
        var phrases: [(piece: Int, words: [TranscriptWord])] = []
        for word in words {
            let middle = moment(of: word)
            guard let piece = offsets.firstIndex(where: { $0.start <= middle && middle < $0.end }) else { continue }
            var moved = word
            let shift = offsets[piece].window.start - offsets[piece].start
            moved.start += shift
            moved.end += shift
            if let last = phrases.last, last.piece == piece, let previous = last.words.last, moved.start - previous.end < pause {
                phrases[phrases.count - 1].words.append(moved)
            } else {
                phrases.append((piece, [moved]))
            }
        }
        return phrases.flatMap { phrase in
            let confidence = phrase.words.reduce(Float(0)) { $0 + ($1.probability ?? 1) } / Float(phrase.words.count)
            return phrase.words.map { ($0, phrase.piece, confidence) }
        }
    }

    /// Today's words where people talk at once given to the voice separation found them in, and words only separation
    /// found there added, unless speech recognition was unsure of that voice's words, the person already has a word
    /// there, or it's a sound speech recognition writes over noise.
    static func merge(_ segments: [TranscriptSegment], found: [Found], activity: Activity) -> (segments: [TranscriptSegment], moved: Int, added: Int) {
        // A word one voice has leaked into the other comes out in both, less sure in the voice it leaked into.
        let found = found.sorted { ($0.word.probability ?? 1, -$0.word.start, $0.voice) > ($1.word.probability ?? 1, -$1.word.start, $1.voice) }
        var speakers = segments.map { segment in (segment.words ?? []).map { _ in segment.speaker } }
        let alone = segments.flatMap { segment in
            (segment.words ?? []).filter { !activity.together(segment.input, around: moment(of: $0), within: margin) }
                .map { (word: $0, speaker: segment.speaker, input: segment.input) }
        }
        var used = Set<Int>()
        var moved = 0
        for (s, segment) in segments.enumerated() {
            for (w, word) in (segment.words ?? []).enumerated() {
                let time = moment(of: word)
                guard activity.together(segment.input, around: time, within: margin) else { continue }
                guard let match = found.indices.first(where: { !used.contains($0) && found[$0].input == segment.input
                    && abs(moment(of: found[$0].word) - time) <= 0.6 && sameWord(found[$0].word.text, word.text) }) else { continue }
                used.insert(match)
                let to = found[match]
                // Where one person stops and another starts, both can come out in the same separated voice.
                let carriesSpeaker = found.contains { other in
                    other.voice == to.voice && other.input == to.input && (other.word.probability ?? 1) >= 0.5
                        && abs(moment(of: other.word) - moment(of: to.word)) <= 2
                        && alone.contains { $0.speaker == segment.speaker && $0.input == segment.input
                            && abs(moment(of: $0.word) - moment(of: other.word)) <= 0.6 && sameWord($0.word.text, other.word.text) }
                }
                if to.speaker != segment.speaker, !carriesSpeaker, activity.heard(to.voice, segment.input, around: time, within: 0.3) {
                    speakers[s][w] = to.speaker
                    moved += 1
                }
            }
        }
        var kept: [(word: TranscriptWord, speaker: String?)] = []
        for (s, segment) in segments.enumerated() {
            for (w, word) in (segment.words ?? []).enumerated() { kept.append((word, speakers[s][w])) }
        }
        var added: [Found] = []
        for (index, item) in found.enumerated() where !used.contains(index) {
            let time = moment(of: item.word)
            guard item.confidence >= confidence,
                  activity.together(item.input, around: time, within: margin),
                  activity.heard(item.voice, item.input, around: time, within: 0.3),
                  !isNoise(item.word.text),
                  !kept.contains(where: { $0.speaker == item.speaker && abs(moment(of: $0.word) - time) <= 0.4 }),
                  !kept.contains(where: { abs(moment(of: $0.word) - time) <= ($0.speaker == item.speaker ? 1.2 : 0.6) && sameWord($0.word.text, item.word.text) }),
                  !added.contains(where: { $0.speaker != item.speaker && abs(moment(of: $0.word) - time) <= 0.6 && sameWord($0.word.text, item.word.text) })
            else { continue }
            added.append(item)
        }

        var result: [TranscriptSegment] = []
        for (s, segment) in segments.enumerated() {
            guard let words = segment.words, !words.isEmpty, speakers[s].contains(where: { $0 != segment.speaker }) else {
                result.append(segment)
                continue
            }
            var start = 0
            for i in 1...words.count where i == words.count || speakers[s][i] != speakers[s][start] {
                let run = Array(words[start..<i])
                result.append(TranscriptSegment(start: run[0].start, end: run[run.count - 1].end, text: run.map(\.text).joined(separator: " "),
                                                speaker: speakers[s][start], words: run, input: segment.input, separated: segment.separated))
                start = i
            }
        }
        for group in groups(added.sorted { $0.word.start < $1.word.start }) {
            result.append(TranscriptSegment(start: group[0].word.start, end: group[group.count - 1].word.end, text: group.map(\.word.text).joined(separator: " "),
                                            speaker: group[0].speaker, words: group.map(\.word), input: group[0].input, separated: true))
        }
        return (result.sorted { $0.start < $1.start }, moved, added.count)
    }

    /// Added words of one person in a row, a segment each.
    private static func groups(_ words: [Found]) -> [[Found]] {
        var groups: [[Found]] = []
        for word in words {
            if let last = groups.last?.last, last.speaker == word.speaker, last.input == word.input, word.word.start - last.word.end < 1 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups
    }

    /// When a word is said. A word's last token can be timed seconds late, so no word counts as longer than 0.6 seconds.
    static func moment(of word: TranscriptWord) -> Double {
        (word.start + min(word.end, word.start + 0.6)) / 2
    }

    /// Two transcriptions of one word: the same letters, or the same but for one of Hebrew's one-letter prefixes or one
    /// letter, or one inside the other.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        let a = ConversationProcessor.normalized(a), b = ConversationProcessor.normalized(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || bare(a) == bare(b) { return true }
        if min(a.count, b.count) >= 3, a.contains(b) || b.contains(a) { return true }
        return min(a.count, b.count) >= 4 && editDistance(a, b) <= 1
    }

    /// Without up to two of Hebrew's one-letter prefixes (ה, ו, ב, ל, כ, מ, ש), which transcriptions add or drop.
    private static func bare(_ word: String) -> String {
        var word = Substring(word)
        for _ in 0..<2 where word.count > 3 && "הובלכמש".contains(word.first!) { word = word.dropFirst() }
        return String(word)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// A sound drawn out over three letters or more ("אהההה"), or the phrase speech recognition writes over noise in
    /// Hebrew ("אדוני היושב-ראש").
    static func isNoise(_ word: String) -> Bool {
        let characters = Array(word)
        if characters.count >= 3, (2..<characters.count).contains(where: { i in
            characters[i].isLetter && characters[i] == characters[i - 1] && characters[i] == characters[i - 2]
        }) { return true }
        return word.contains("אדוני") || word.contains("היושב")
    }
}

/// Where each voice the timeline found is heard, in frames of 10 ms, input by input.
struct Activity {
    private struct Key: Hashable {
        let input: RecordingInput?
        let voice: String
    }

    private var frames: [Key: [Bool]] = [:]
    private let count: Int

    init(_ turns: [SpeakerTurn], length: Double) {
        count = Int(length / OverlapSeparation.frame) + 2
        for turn in turns {
            let key = Key(input: turn.input, voice: turn.voice)
            if frames[key] == nil { frames[key] = [Bool](repeating: false, count: count) }
            let from = max(0, Int(turn.start / OverlapSeparation.frame)), to = min(count, Int(turn.end / OverlapSeparation.frame))
            guard from < to else { continue }
            for i in from..<to { frames[key]![i] = true }
        }
    }

    /// Where two voices or more of the same input are heard at once.
    func moments() -> [OverlapSeparation.Stretch] {
        var moments: [OverlapSeparation.Stretch] = []
        for input in Set(frames.keys.map(\.input)) {
            let voices = frames.filter { $0.key.input == input }.map(\.value)
            var start: Int?
            for i in 0...count {
                let together = i < count && voices.filter({ $0[i] }).count >= 2
                if together, start == nil { start = i }
                if !together, let from = start {
                    moments.append(.init(start: Double(from) * OverlapSeparation.frame, end: Double(i) * OverlapSeparation.frame, input: input))
                    start = nil
                }
            }
        }
        return moments.sorted { $0.start < $1.start }
    }

    func together(_ input: RecordingInput?, around time: Double, within seconds: Double) -> Bool {
        let range = window(time, seconds)
        let voices = frames.filter { $0.key.input == input }.map(\.value)
        return range.contains { i in voices.filter { $0[i] }.count >= 2 }
    }

    func heard(_ voice: String, _ input: RecordingInput?, around time: Double, within seconds: Double) -> Bool {
        guard let voice = frames[Key(input: input, voice: voice)] else { return false }
        return window(time, seconds).contains { voice[$0] }
    }

    /// Who a window's two separated voices are at a moment of two at once: the two heard most then, matched by when
    /// each separated voice is loud against when each is heard, from a second before the moment to a second after.
    func voices(of separated: [[Float]], at moment: OverlapSeparation.Stretch, in window: OverlapSeparation.Stretch) -> [String] {
        let frame = OverlapSeparation.frame
        let first = Int(window.start / frame)
        let from = min(count, Int(moment.start / frame)), to = min(count, max(from + 1, Int(moment.end / frame)))
        let heard = frames.filter { $0.key.input == window.input }
            .map { (voice: $0.key.voice, active: $0.value, during: $0.value[from..<to].filter { $0 }.count) }
            .filter { $0.during > 0 }
            .sorted { ($0.during, $0.voice) > ($1.during, $1.voice) }
            .prefix(2)
        let span = separated.first.map { $0.count / 160 } ?? 0
        let around = max(0, Int((moment.start - 1 - window.start) / frame))..<min(span, Int((moment.end + 1 - window.start) / frame))
        guard heard.count == 2, separated.count == 2, !around.isEmpty else { return heard.map(\.voice) }
        let loudness = separated.map { voice in
            around.map { i in log(max(1e-9, (voice[i * 160..<min(voice.count, (i + 1) * 160)].reduce(0) { $0 + $1 * $1 } / 160).squareRoot())) }
        }
        let activity = heard.map { voice in around.map { first + $0 < count && voice.active[first + $0] ? Float(1) : 0 } }
        let straight = Self.correlation(loudness[0], activity[0]) + Self.correlation(loudness[1], activity[1])
        let crossed = Self.correlation(loudness[0], activity[1]) + Self.correlation(loudness[1], activity[0])
        return crossed > straight ? [heard[1].voice, heard[0].voice] : [heard[0].voice, heard[1].voice]
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let meanA = a.reduce(0, +) / Float(a.count), meanB = b.reduce(0, +) / Float(b.count)
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += (a[i] - meanA) * (b[i] - meanB)
            normA += (a[i] - meanA) * (a[i] - meanA)
            normB += (b[i] - meanB) * (b[i] - meanB)
        }
        return normA > 0 && normB > 0 ? dot / (normA * normB).squareRoot() : 0
    }

    private func window(_ time: Double, _ seconds: Double) -> Range<Int> {
        let from = max(0, Int((time - seconds) / OverlapSeparation.frame)), to = min(count, Int((time + seconds) / OverlapSeparation.frame) + 1)
        return from < to ? from..<to : 0..<0
    }
}
