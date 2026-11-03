import BekitzurAudio
import BekitzurDomain
import BekitzurSpeakers
import BekitzurTranscription
import Foundation

/// Where the live transcriber's chunks are transcribed: in this process, or in a helper process that can crash without
/// taking the recording with it.
public protocol LiveChunkTranscriber: Sendable {
    /// Transcribes a chunk that starts `offset` seconds into the recording. `done` gets its segments, already placed in
    /// the recording, or nil if transcription failed, and their language once it's known. Chunks are answered in the
    /// order they were sent; while the language is being detected, chunks with speech wait until it's decided.
    func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void)
    /// After the last chunk; `done` runs once every chunk has been answered.
    func finish(_ done: @escaping @Sendable () -> Void)
    /// Stops without waiting for answers, as when the app quits while recording.
    func cancel()
}

/// How a chunk is transcribed, wherever that happens.
public enum LiveChunks {
    /// Only where someone speaks, by the speech detector: given room noise, ivrit.ai's model writes Knesset openings
    /// and "תודה רבה". Speech less than 2 seconds apart is one piece, so a pause doesn't split a sentence; a chunk without
    /// speech gives nothing. Without a detector (`detected` nil), the whole chunk is one piece.
    static func transcribe(
        _ samples: [Float],
        at offset: Double,
        speech detected: [ClosedRange<Double>]?,
        with transcriber: Transcriber,
        language: ConversationLanguage
    ) throws -> [TranscriptSegment] {
        let duration = Double(samples.count) / AudioLoader.sampleRate
        return try pieces(detected ?? [0...duration]).flatMap { piece -> [TranscriptSegment] in
            let start = Int(max(0, piece.lowerBound) * AudioLoader.sampleRate)
            let end = min(samples.count, Int(piece.upperBound * AudioLoader.sampleRate))
            guard end > start else { return [] }
            let from = Double(start) / AudioLoader.sampleRate
            let speech = detected?.filter { piece.overlaps($0) }.map { ($0.lowerBound - from)...($0.upperBound - from) }
            return try transcribePiece(Array(samples[start..<end]), at: offset + from, speech: speech, with: transcriber, language: language)
        }
    }

    /// Speech stretches less than `gap` seconds apart, joined.
    static func pieces(_ speech: [ClosedRange<Double>], gap: Double = 2) -> [ClosedRange<Double>] {
        var pieces: [ClosedRange<Double>] = []
        for range in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = pieces.last, range.lowerBound - last.upperBound < gap {
                pieces[pieces.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                pieces.append(range)
            }
        }
        return pieces
    }

    /// One segment per window, so whisper.cpp never opens a second window on what's left after the last segment; if
    /// that window holds a segment ending within 0.15 seconds of its start, word timing aborts the process. A piece
    /// under a second gets silence after it, since word timing also needs more audio than its 7-step median filter.
    /// The segment is then split into sentences and moved to where the piece starts.
    ///
    /// A single segment can end early, over a sound effect for instance, and whisper.cpp then skips the rest of the
    /// window; when the detector heard at least 2 seconds of uninterrupted speech after the last word, transcription
    /// starts again from that word. Shorter sounds are usually a click or a cough, which Whisper turns into a Knesset
    /// opening.
    static func transcribePiece(
        _ samples: [Float],
        at offset: Double,
        speech: [ClosedRange<Double>]?,
        with transcriber: Transcriber,
        language: ConversationLanguage
    ) throws -> [TranscriptSegment] {
        let duration = Double(samples.count) / AudioLoader.sampleRate
        var segments: [TranscriptSegment] = []
        var from = 0.0
        for _ in 0..<5 {
            var part = Array(samples[Int(from * AudioLoader.sampleRate)...])
            let end = Double(part.count) / AudioLoader.sampleRate
            if part.count < 16_000 { part += [Float](repeating: 0, count: 16_000 - part.count) }
            let found = try transcriber.transcribe(part, language: language, asOneSegment: true)
                .flatMap { sentences(fitted($0, end: end)) }
                .filter { $0.start < end }
            segments += found.map { $0.shifted(by: offset + from) }
            guard let last = found.last?.words?.last?.end ?? found.last?.end else { break }
            let resume = from + last
            guard speech?.contains(where: { $0.upperBound - max($0.lowerBound, resume + 0.3) >= 2 }) == true else { break }
            from = resume
        }
        return segments
    }

    /// Runs async work from synchronous code on a thread that may wait, like the helper's main loop.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                outcome.result = .success(try await work())
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try outcome.result!.get()
    }

    /// A one-segment window is timed as the whole 30-second window; its words say where the speech is.
    static func fitted(_ segment: TranscriptSegment, end: Double) -> TranscriptSegment {
        var fitted = segment
        fitted.start = segment.words?.first?.start ?? segment.start
        fitted.end = min(segment.words?.last?.end ?? segment.end, end)
        return fitted
    }

    /// The segment split after each word that ends a sentence, so lines read as they do from a whole file.
    static func sentences(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        guard let words = segment.words, !words.isEmpty else { return [segment] }
        var sentences: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            guard index == words.count - 1 || word.text.last.map({ ".?!".contains($0) }) == true else { continue }
            sentences.append(TranscriptSegment(start: current[0].start, end: word.end, text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }
        return sentences
    }

    /// A chunk as the helper reads it: where it starts (seconds, Float64), how many samples (UInt32), then the samples
    /// (Float32), all in this Mac's byte order.
    static func message(_ samples: [Float], at offset: Double) -> Data {
        var data = Data(capacity: 12 + samples.count * 4)
        withUnsafeBytes(of: offset) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(samples.count)) { data.append(contentsOf: $0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Reads the next chunk with `read`, which returns up to the bytes asked for and empty data at the end of input.
    static func readMessage(_ read: (Int) -> Data) -> (samples: [Float], offset: Double)? {
        func exactly(_ count: Int) -> Data? {
            var data = Data()
            while data.count < count {
                let more = read(count - data.count)
                if more.isEmpty { return nil }
                data += more
            }
            return data
        }
        guard let header = exactly(12) else { return nil }
        let offset = header.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let count = Int(header.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard let body = count == 0 ? Data() : exactly(count * 4) else { return nil }
        let samples = body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (samples, offset)
    }

    /// One line per chunk: its segments, or null if it couldn't be transcribed, and their language once it's known.
    struct Answer: Codable {
        let segments: [TranscriptSegment]?
        var language: ConversationLanguage? = nil

        static let failed = Answer(segments: nil)
        static let nothing = Answer(segments: [])
    }
}

/// Tells Hebrew from English by the first speech, with whisper.cpp's language detection on regular Whisper: ivrit.ai's
/// model answers Hebrew, all but certain, even for English.
///
/// 10 seconds of speech gives the right language a high probability, and 30 seconds a near-certain one.
enum LanguageDetection {
    /// Speech heard before the first guess.
    static let firstGuess = 10.0
    /// Whisper detects from 30 seconds of audio at most.
    static let longest = 30.0
    static let sure: Float = 0.95

    /// The likelier language once whisper is sure of it, has heard 30 seconds of speech, or will hear no more; nil to
    /// wait for more speech.
    static func decision(_ probabilities: [ConversationLanguage: Float], heard seconds: Double, ended: Bool) -> ConversationLanguage? {
        guard let likeliest = probabilities.max(by: { $0.value < $1.value }) else { return nil }
        return likeliest.value >= sure || seconds >= longest || ended ? likeliest.key : nil
    }
}

/// Transcribes chunks in order, in the helper process or on a thread of this one. While the language isn't known,
/// a chunk with speech waits, with every chunk after it, and its speech is gathered for `LanguageDetection`; once the
/// language is decided they're all transcribed with its model. Without the speech detector (its model couldn't be
/// loaded), chunks are transcribed whole.
final class ChunkSession {
    /// Where a chunk has speech, in seconds from its start; nil to transcribe it whole.
    typealias SpeechFinder = ([Float]) throws -> [ClosedRange<Double>]?

    private let findSpeech: SpeechFinder
    private var language: ConversationLanguage?
    /// The language's model, once it's known.
    private var transcriber: Transcriber?
    /// Regular Whisper, which is also the English model, until the language is known.
    private var detecting: Transcriber?
    private var waiting: [Chunk] = []
    /// The waiting chunks' speech, up to what detection hears.
    private var heard: [Float] = []
    private var failed = false

    /// `speech` nil means the whole chunk; a chunk without speech keeps no samples.
    private struct Chunk {
        let samples: [Float]
        let offset: Double
        let speech: [ClosedRange<Double>]?
    }

    /// - Parameters:
    ///   - language: Nil to detect it.
    ///   - model: A speech model to transcribe with instead of the language's; only with a language.
    convenience init(language: ConversationLanguage?, model: URL? = nil, detectsSpeech: Bool) throws {
        let detector = detectsSpeech ? try? LiveChunks.blocking { try await SpeechDetector() } : nil
        try self.init(language: language, model: model) { samples in
            try detector.map { detector in try LiveChunks.blocking { try await detector.speech(in: samples) } }
        }
    }

    init(language: ConversationLanguage?, model: URL? = nil, findSpeech: @escaping SpeechFinder) throws {
        self.language = language
        self.findSpeech = findSpeech
        if let language {
            transcriber = try Transcriber(modelURL: model ?? BekitzurPaths.speechModel(for: language))
        } else {
            detecting = try Transcriber(modelURL: BekitzurPaths.speechModel(for: .english))
        }
    }

    /// The answers this chunk lets out: its own, none while it waits for the language, or every waiting chunk's once
    /// it's decided. After a failure, every chunk's answer is nil.
    func answer(_ samples: [Float], at offset: Double) -> [LiveChunks.Answer] {
        guard !failed else { return [.failed] }
        let speech: [ClosedRange<Double>]?
        do {
            speech = try findSpeech(samples)
        } catch {
            waiting.append(Chunk(samples: [], offset: offset, speech: []))
            return fail()
        }
        let silent = speech?.isEmpty == true
        if language == nil {
            if waiting.isEmpty, silent { return [.nothing] }
            hear(samples, speech: speech)
        }
        waiting.append(Chunk(samples: silent ? [] : samples, offset: offset, speech: speech))
        return answerWaiting(ended: false)
    }

    /// The waiting chunks' answers, once there are no more chunks.
    func finish() -> [LiveChunks.Answer] {
        failed ? [] : answerWaiting(ended: true)
    }

    private func answerWaiting(ended: Bool) -> [LiveChunks.Answer] {
        do {
            if language == nil, !waiting.isEmpty {
                let seconds = Double(heard.count) / AudioLoader.sampleRate
                guard let detecting, !heard.isEmpty, seconds >= LanguageDetection.firstGuess || ended else {
                    return ended ? waitingAnswers { _ in .nothing } : []
                }
                let probabilities = try detecting.detectLanguage(heard).probabilities
                guard let decided = LanguageDetection.decision(probabilities, heard: seconds, ended: ended) else { return [] }
                try use(decided)
            }
            guard let language, let transcriber else { return waitingAnswers { _ in .nothing } }
            return try waitingAnswers { chunk in
                LiveChunks.Answer(
                    segments: try LiveChunks.transcribe(chunk.samples, at: chunk.offset, speech: chunk.speech, with: transcriber, language: language),
                    language: language
                )
            }
        } catch {
            return fail()
        }
    }

    /// Switches from detecting to transcribing; regular Whisper is let go before ivrit.ai's model loads.
    private func use(_ decided: ConversationLanguage) throws {
        if decided == .english { transcriber = detecting }
        detecting = nil
        heard = []
        if transcriber == nil { transcriber = try Transcriber(modelURL: BekitzurPaths.speechModel(for: decided)) }
        language = decided
    }

    /// Adds a chunk's speech to what detection hears.
    private func hear(_ samples: [Float], speech: [ClosedRange<Double>]?) {
        let rate = AudioLoader.sampleRate
        let most = Int(LanguageDetection.longest * rate)
        for range in speech ?? [0...(Double(samples.count) / rate)] where heard.count < most {
            let from = max(0, Int(range.lowerBound * rate))
            let to = min(samples.count, Int(range.upperBound * rate), from + most - heard.count)
            if from < to { heard += samples[from..<to] }
        }
    }

    private func waitingAnswers(_ answer: (Chunk) throws -> LiveChunks.Answer) rethrows -> [LiveChunks.Answer] {
        let answers = try waiting.map(answer)
        waiting = []
        return answers
    }

    private func fail() -> [LiveChunks.Answer] {
        failed = true
        return waitingAnswers { _ in .failed }
    }
}

/// The result of async work that synchronous code waits for; written once, before the wait ends.
private final class Outcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Transcribes chunks on a low-priority thread of this process; used by tests and tools.
public final class InProcessChunkTranscriber: LiveChunkTranscriber, @unchecked Sendable {
    private let language: ConversationLanguage?
    private let model: URL?
    private let detectsSpeech: Bool
    private let queue = DispatchQueue(label: "bekitzur.live-chunks", qos: .utility)
    private var session: ChunkSession?
    private var waiting: [@Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void] = []

    /// - Parameters:
    ///   - language: Nil to detect it from the first speech.
    ///   - model: A speech model to transcribe with instead of the language's; only with a language.
    ///   - detectsSpeech: Transcribe only where someone speaks; otherwise every chunk whole.
    public init(language: ConversationLanguage?, model: URL? = nil, detectsSpeech: Bool = true) {
        self.language = language
        self.model = model
        self.detectsSpeech = detectsSpeech
    }

    public func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void) {
        queue.async {
            self.waiting.append(done)
            if self.session == nil {
                self.session = try? ChunkSession(language: self.language, model: self.model, detectsSpeech: self.detectsSpeech)
            }
            self.deliver(self.session?.answer(samples, at: offset) ?? [.failed])
        }
    }

    public func finish(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            self.deliver(self.session?.finish() ?? [])
            done()
        }
    }

    public func cancel() {}

    private func deliver(_ answers: [LiveChunks.Answer]) {
        for answer in answers {
            waiting.removeFirst()(answer.segments, answer.language)
        }
    }
}

/// Transcribes chunks in a helper process running `LiveTranscriptionHelper.serve`, so that a crash in whisper.cpp ends
/// only live transcription, never the recording. If the helper dies, every chunk not yet answered gets nil.
public final class HelperChunkTranscriber: LiveChunkTranscriber, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writes = DispatchQueue(label: "bekitzur.live-helper-input", qos: .utility)
    private let lock = NSLock()
    private var waiting: [@Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void] = []
    private var finished: (@Sendable () -> Void)?
    private var ended = false

    /// - Parameters:
    ///   - executable: A program that serves chunks on its standard input, like the app run with `arguments`.
    public init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        // Writing to a helper that has died then fails with EPIPE instead of sending SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            ended = true
            return
        }
        Thread.detachNewThread { [self] in readAnswers() }
    }

    public func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void) {
        lock.lock()
        let alive = !ended
        if alive { waiting.append(done) }
        lock.unlock()
        guard alive else { return done(nil, nil) }
        let message = LiveChunks.message(samples, at: offset)
        writes.async { [input] in
            try? input.fileHandleForWriting.write(contentsOf: message)
        }
    }

    public func finish(_ done: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyEnded = ended
        if !alreadyEnded { finished = done }
        lock.unlock()
        if alreadyEnded { return done() }
        writes.async { [input] in
            try? input.fileHandleForWriting.close()
        }
    }

    public func cancel() {
        if process.isRunning { process.terminate() }
    }

    /// Answers waiting chunks in order, one line each, until the helper's output ends.
    private func readAnswers() {
        let handle = output.fileHandleForReading
        var buffer = Data()
        while true {
            let more = handle.availableData
            if more.isEmpty { break }
            buffer += more
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let answer = try? JSONDecoder().decode(LiveChunks.Answer.self, from: line)
                lock.lock()
                let done = waiting.isEmpty ? nil : waiting.removeFirst()
                lock.unlock()
                done?(answer?.segments, answer?.language)
            }
        }
        process.waitUntilExit()
        lock.lock()
        ended = true
        let unanswered = waiting
        waiting = []
        let finished = self.finished
        lock.unlock()
        unanswered.forEach { $0(nil, nil) }
        finished?()
    }
}

/// The helper process's side: reads chunks on standard input until it ends, and answers each with one line of JSON on
/// standard output; chunks waiting for the language are answered once it's decided, or when the input ends.
/// whisper.cpp logs to standard error.
public enum LiveTranscriptionHelper {
    /// The language argument that says to detect it.
    public static let detect = "auto"

    /// - Parameters:
    ///   - language: Nil to detect it from the first speech.
    ///   - model: A speech model to transcribe with instead of the language's; only with a language.
    public static func serve(language: ConversationLanguage?, model: URL? = nil, detectsSpeech: Bool = true) -> Int32 {
        guard let session = try? ChunkSession(language: language, model: model, detectsSpeech: detectsSpeech) else { return 1 }
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        func send(_ answers: [LiveChunks.Answer]) -> Bool {
            for answer in answers {
                guard var line = try? JSONEncoder().encode(answer) else { return false }
                line.append(UInt8(ascii: "\n"))
                do {
                    try output.write(contentsOf: line)
                } catch {
                    return false
                }
            }
            return true
        }
        while let chunk = LiveChunks.readMessage({ (try? input.read(upToCount: $0)) ?? Data() }) {
            guard send(session.answer(chunk.samples, at: chunk.offset)) else { return 1 }
        }
        return send(session.finish()) ? 0 : 1
    }
}
