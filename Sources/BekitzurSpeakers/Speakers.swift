import BekitzurDomain
import Foundation

/// A Speaker found in one Recording: all the speech of one voice.
public struct Speaker: Sendable {
    /// "Speaker 1", "Speaker 2", … in order of first speech.
    public let label: String
    public let voice: String
    public let speechSeconds: Double
    public let centroid: [Float]
    public var naming: SpeakerNaming = .unknown
    public var similarities: [String: Float] = [:]

    /// The name to show in the Transcript.
    public var displayName: String {
        if case .named(let name, _) = naming { return name }
        return label
    }
}

public enum Speakers {
    /// Similarity at or above which a match is confident enough to name the Speaker without asking.
    /// In clear speech, the same person scores well above these and different people well below; tune with daily use.
    public static let confidentSimilarity: Float = 0.65
    public static let suggestSimilarity: Float = 0.45
    /// A confident match must also beat the Speaker's next-best Participant, and every other Speaker's similarity to
    /// the same Participant, by this much. In a recording where far voices are faint, every voice can look alike.
    public static let confidentMargin: Float = 0.15

    /// Groups turns by voice, with each voice's duration-weighted average embedding.
    public static func speakers(from turns: [SpeakerTurn]) -> [Speaker] {
        let byVoice = Dictionary(grouping: turns, by: \.voice)
        let ordered = byVoice.keys.sorted { byVoice[$0]!.map(\.start).min()! < byVoice[$1]!.map(\.start).min()! }
        return ordered.enumerated().map { index, voice in
            let voiceTurns = byVoice[voice]!
            return Speaker(
                label: SpeakerLabel.label(index + 1),
                voice: voice,
                speechSeconds: voiceTurns.map(\.duration).reduce(0, +),
                centroid: weightedMean(voiceTurns)
            )
        }
    }

    /// The Voiceprint of the voice that speaks most in a voice sample.
    public static func voiceprint(named name: String, from turns: [SpeakerTurn]) -> Voiceprint? {
        speakers(from: turns).max { $0.speechSeconds < $1.speechSeconds }.map { Voiceprint(name: name, embedding: $0.centroid) }
    }

    /// Names Speakers from Voiceprints. Each Participant goes to at most one Speaker, best matches first.
    public static func name(_ speakers: [Speaker], with voiceprints: [Voiceprint]) -> [Speaker] {
        var result = speakers
        for i in result.indices {
            result[i].similarities = Dictionary(uniqueKeysWithValues: voiceprints.map { ($0.name, cosine(result[i].centroid, $0.embedding)) })
        }
        let pairs = result.indices.flatMap { i in voiceprints.map { (i, $0.name, result[i].similarities[$0.name]!) } }
        var takenSpeakers = Set<Int>(), takenNames = Set<String>()
        for (i, name, similarity) in pairs.sorted(by: { $0.2 > $1.2 }) where similarity >= suggestSimilarity {
            guard !takenSpeakers.contains(i), !takenNames.contains(name) else { continue }
            let runnerUp = result[i].similarities.filter { $0.key != name }.values.max() ?? 0
            let rival = result.indices.filter { $0 != i }.compactMap { result[$0].similarities[name] }.max() ?? 0
            result[i].naming = similarity >= confidentSimilarity && similarity - max(runnerUp, rival) >= confidentMargin
                ? .named(name, similarity: similarity)
                : .suggested(name, similarity: similarity)
            takenSpeakers.insert(i)
            takenNames.insert(name)
        }
        return result
    }

    /// Gives each stretch of the Transcript the Speaker talking at that moment, splitting a segment wherever the
    /// Speaker changes between its words. A word between turns goes to the nearest turn within a second, or else
    /// keeps the Speaker of the words around it. Segments without word times go to whoever talks most during them.
    /// A stretch transcribed from one of a call's tracks goes to the voices heard in that track, and one from the
    /// microphone that goes to a voice also in the system audio is left out: the system audio's Transcript has that
    /// person's words, and what the microphone makes of them is what's left of their voice, sometimes misheard, or
    /// speech recognition's "תודה רבה" over near silence.
    public static func attribute(_ segments: [TranscriptSegment], turns allTurns: [SpeakerTurn], speakers: [Speaker]) -> [TranscriptSegment] {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.voice, $0.displayName) })
        let byInput = Dictionary(grouping: allTurns.filter { $0.input != nil }, by: { $0.input! })
        let inSystemAudio = Set((byInput[.systemAudio] ?? []).compactMap { names[$0.voice] })
        var result: [TranscriptSegment] = []
        for segment in segments {
            let turns = segment.input.flatMap { byInput[$0] } ?? allTurns
            guard let words = segment.words, !words.isEmpty else {
                var attributed = segment
                attributed.speaker = mostTalking(from: segment.start, to: segment.end, in: turns).flatMap { names[$0] }
                result.append(attributed)
                continue
            }
            var labels = words.map { talking(at: moment(of: $0), in: turns).flatMap { names[$0] } }
            var previous = result.last { $0.input == segment.input }?.speaker
            for i in labels.indices {
                if let label = labels[i] { previous = label } else { labels[i] = previous }
            }
            var next: String?
            for i in labels.indices.reversed() {
                if let label = labels[i] { next = label } else { labels[i] = next }
            }

            var runStart = 0
            for i in 1...words.count where i == words.count || labels[i] != labels[runStart] {
                let run = Array(words[runStart..<i])
                defer { runStart = i }
                if segment.input == .microphone, let label = labels[runStart], inSystemAudio.contains(label) { continue }
                result.append(TranscriptSegment(
                    start: run.first!.start,
                    end: run.last!.end,
                    text: run.count == words.count ? segment.text : run.map(\.text).joined(separator: " "),
                    speaker: labels[runStart],
                    words: run,
                    input: segment.input
                ))
            }
        }
        return result
    }

    private static func mostTalking(from start: Double, to end: Double, in turns: [SpeakerTurn]) -> String? {
        var overlap: [String: Double] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 { overlap[turn.voice, default: 0] += shared }
        }
        return overlap.max { $0.value < $1.value }?.key
    }

    /// When a word is said. A word's last token can be timed seconds late, so no word counts as longer than 0.6 seconds.
    private static func moment(of word: TranscriptWord) -> Double {
        (word.start + min(word.end, word.start + 0.6)) / 2
    }

    /// The voice talking at a moment. Where turns overlap because one runs on as the next speaker starts, it's the
    /// speaker who started last; otherwise (a short reply inside a long turn) it's the turn that contains the moment
    /// most deeply. Between turns, it's the nearest turn within a second.
    private static func talking(at time: Double, in turns: [SpeakerTurn]) -> String? {
        let containing = turns.filter { $0.start <= time && time <= $0.end }
        if let latest = containing.max(by: { $0.start < $1.start }), containing.count > 1,
           containing.allSatisfy({ $0.end <= latest.end }) {
            return latest.voice
        }
        if let deepest = containing.max(by: { min(time - $0.start, $0.end - time) < min(time - $1.start, $1.end - time) }) {
            return deepest.voice
        }
        let nearest = turns.min { distance(time, $0) < distance(time, $1) }
        return nearest.flatMap { distance(time, $0) <= 1 ? $0.voice : nil }
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        time < turn.start ? turn.start - time : time - turn.end
    }

    /// Shortest total speech for a voice to count as a person rather than a blip: 10 seconds, or 5% of all the speech
    /// in a short Conversation, and at least 3 seconds. Separators can split off a few seconds of one person as
    /// another voice.
    public static func minimumVoiceSeconds(amid turns: [SpeakerTurn]) -> Double {
        max(3, min(10, 0.05 * turns.map(\.duration).reduce(0, +)))
    }

    /// How many voices in `turns` speak long enough to count as people.
    static func voices(in turns: [SpeakerTurn]) -> Int {
        let minimum = minimumVoiceSeconds(amid: turns)
        return Dictionary(grouping: turns, by: \.voice).values.filter { $0.map(\.duration).reduce(0, +) >= minimum }.count
    }

    /// Keeps `timeline`'s turns (who spoke when) and gives each of its voices the label and embedding of the
    /// `identities` voice it overlaps most. Voices are matched one to one, longest first. A voice with no match is
    /// dropped when it's too brief to be a person, so its words go to the turns around it; a longer one stays a voice of
    /// its own, without an embedding, unless the user said how many people spoke and `identities` has that many: then it
    /// joins the voice it overlaps most.
    ///
    /// A timeline with fewer voices that count as people than `identities` heard two people as one, and then
    /// `identities` are kept as they are: matching voices one to one would leave one of the two with almost no speech.
    /// Two Speakers who are one person can be joined by giving them the same name, but two people in one Speaker can only
    /// be fixed word by word.
    public static func combine(timeline: [SpeakerTurn], identities: [SpeakerTurn], people: Int? = nil) -> [SpeakerTurn] {
        guard voices(in: timeline) >= voices(in: identities) else { return identities }
        let foldExtraVoices = people != nil && people == Set(identities.map(\.voice)).count
        let minimumVoiceSeconds = minimumVoiceSeconds(amid: timeline)
        let centroids = Dictionary(grouping: identities, by: \.voice).mapValues(weightedMean)
        var overlap: [String: [String: Double]] = [:]
        for turn in timeline {
            for identity in identities {
                let shared = min(turn.end, identity.end) - max(turn.start, identity.start)
                if shared > 0 { overlap[turn.voice, default: [:]][identity.voice, default: 0] += shared }
            }
        }
        let speech = Dictionary(grouping: timeline, by: \.voice).mapValues { $0.map(\.duration).reduce(0, +) }
        var match: [String: String] = [:]
        var taken = Set<String>()
        for voice in speech.keys.sorted(by: { speech[$0]! > speech[$1]! }) {
            let candidates = (overlap[voice] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
            if let free = candidates.first(where: { !taken.contains($0) }) {
                match[voice] = free
                taken.insert(free)
            } else if foldExtraVoices, speech[voice]! >= minimumVoiceSeconds, let nearest = candidates.first {
                match[voice] = nearest
            }
        }
        return timeline.compactMap { turn in
            guard let identity = match[turn.voice] else {
                // Both separators name voices "S1", "S2", …, so an unmatched label could merge into a matched one.
                guard speech[turn.voice]! >= minimumVoiceSeconds else { return nil }
                return SpeakerTurn(voice: "timeline \(turn.voice)", start: turn.start, end: turn.end, embedding: [])
            }
            return SpeakerTurn(voice: identity, start: turn.start, end: turn.end, embedding: centroids[identity] ?? [])
        }
    }

    static func weightedMean(_ turns: [SpeakerTurn]) -> [Float] {
        guard let width = turns.first?.embedding.count else { return [] }
        var sum = [Float](repeating: 0, count: width)
        var total: Float = 0
        for turn in turns where turn.embedding.count == width {
            let weight = Float(turn.duration)
            for k in 0..<width { sum[k] += weight * turn.embedding[k] }
            total += weight
        }
        return total > 0 ? sum.map { $0 / total } : sum
    }

    /// The average direction of two embeddings, each scaled to unit length first so neither dominates.
    public static func average(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count else { return b }
        let unitA = unit(a), unitB = unit(b)
        return unit(zip(unitA, unitB).map { ($0 + $1) / 2 })
    }

    static func unit(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for k in a.indices {
            dot += a[k] * b[k]
            normA += a[k] * a[k]
            normB += b[k] * b[k]
        }
        return normA > 0 && normB > 0 ? dot / (normA.squareRoot() * normB.squareRoot()) : 0
    }
}
