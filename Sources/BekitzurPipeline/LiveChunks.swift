import BekitzurAudio
import BekitzurDomain
import BekitzurSpeakers
import BekitzurTranscription
import Foundation

/// Where the live transcriber's chunks are transcribed: in this process, or in a helper process that can crash without
/// taking the recording with it.
public protocol LiveChunkTranscriber: Sendable {
    /// Transcribes a chunk that starts `offset` seconds into the recording. `done` gets its segments, already placed in
    /// the recording, or nil if transcription failed; chunks are answered in the order they were sent.
    func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?) -> Void)
    /// After the last chunk; `done` runs once every chunk has been answered.
    func finish(_ done: @escaping @Sendable () -> Void)
    /// Stops without waiting for answers, as when the app quits while recording.
    func cancel()
}

/// How a chunk is transcribed, wherever that happens.
public enum LiveChunks {
    /// Only where someone speaks: given room noise, ivrit.ai's model writes Knesset openings and "תודה רבה". Speech
    /// less than 2 seconds apart is one piece, so a pause doesn't split a sentence; a chunk without speech gives nothing.
    /// Without a detector, the whole chunk is one piece.
    public static func transcribe(
        _ samples: [Float],
        at offset: Double,
        with transcriber: Transcriber,
        detector: SpeechDetector?,
        language: ConversationLanguage
    ) throws -> [TranscriptSegment] {
        let duration = Double(samples.count) / AudioLoader.sampleRate
        let detected = try detector.map { detector in try blocking { try await detector.speech(in: samples) } }
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
    /// that window held a segment ending within 0.15 seconds of its start, word timing aborted the process. A piece
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

    /// One line per chunk: its segments, or null if it couldn't be transcribed.
    struct Answer: Codable {
        let segments: [TranscriptSegment]?
    }
}

/// The result of async work that synchronous code waits for; written once, before the wait ends.
private final class Outcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Transcribes chunks on a low-priority thread of this process; used by tests and tools.
public final class InProcessChunkTranscriber: LiveChunkTranscriber, @unchecked Sendable {
    private let modelURL: URL
    private let language: ConversationLanguage
    private let detectsSpeech: Bool
    private let queue = DispatchQueue(label: "bekitzur.live-chunks", qos: .utility)
    private var transcriber: Transcriber?
    private var detector: SpeechDetector?

    /// - Parameter detectsSpeech: Transcribe only where someone speaks; otherwise every chunk whole.
    public init(modelURL: URL, language: ConversationLanguage, detectsSpeech: Bool = true) {
        self.modelURL = modelURL
        self.language = language
        self.detectsSpeech = detectsSpeech
    }

    public func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?) -> Void) {
        queue.async {
            do {
                if self.transcriber == nil {
                    self.transcriber = try Transcriber(modelURL: self.modelURL)
                    if self.detectsSpeech { self.detector = try? LiveChunks.blocking { try await SpeechDetector() } }
                }
                done(try LiveChunks.transcribe(samples, at: offset, with: self.transcriber!, detector: self.detector, language: self.language))
            } catch {
                done(nil)
            }
        }
    }

    public func finish(_ done: @escaping @Sendable () -> Void) {
        queue.async(execute: done)
    }

    public func cancel() {}
}

/// Transcribes chunks in a helper process running `LiveTranscriptionHelper.serve`, so that a crash in whisper.cpp ends
/// only live transcription, never the recording. If the helper dies, every chunk not yet answered gets nil.
public final class HelperChunkTranscriber: LiveChunkTranscriber, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writes = DispatchQueue(label: "bekitzur.live-helper-input", qos: .utility)
    private let lock = NSLock()
    private var waiting: [@Sendable ([TranscriptSegment]?) -> Void] = []
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

    public func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?) -> Void) {
        lock.lock()
        let alive = !ended
        if alive { waiting.append(done) }
        lock.unlock()
        guard alive else { return done(nil) }
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
                done?(answer?.segments)
            }
        }
        process.waitUntilExit()
        lock.lock()
        ended = true
        let unanswered = waiting
        waiting = []
        let finished = self.finished
        lock.unlock()
        unanswered.forEach { $0(nil) }
        finished?()
    }
}

/// The helper process's side: reads chunks on standard input until it ends, and answers each with one line of JSON on
/// standard output. whisper.cpp logs to standard error. Without the speech detector (its model couldn't be loaded),
/// chunks are transcribed whole.
public enum LiveTranscriptionHelper {
    public static func serve(modelURL: URL, language: ConversationLanguage, detectsSpeech: Bool = true) -> Int32 {
        guard let transcriber = try? Transcriber(modelURL: modelURL) else { return 1 }
        let detector = detectsSpeech ? try? LiveChunks.blocking { try await SpeechDetector() } : nil
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        while let chunk = LiveChunks.readMessage({ (try? input.read(upToCount: $0)) ?? Data() }) {
            let segments = try? LiveChunks.transcribe(chunk.samples, at: chunk.offset, with: transcriber, detector: detector, language: language)
            guard var line = try? JSONEncoder().encode(LiveChunks.Answer(segments: segments)) else { return 1 }
            line.append(UInt8(ascii: "\n"))
            do {
                try output.write(contentsOf: line)
            } catch {
                return 1
            }
        }
        return 0
    }
}
