import AVFoundation
import BekitzurAudio
import BekitzurDomain
import Foundation

/// Transcribes a Conversation while it's recorded, so the Transcript is nearly done when the recording stops.
///
/// Each track's audio arrives on its recorder's thread and is only copied there. Every two seconds, on a low-priority
/// thread, the tracks are converted to 16 kHz and summed, as `ConversationProcessor.loadMixed` does with the files, and
/// the mix is cut into chunks of 20 to 30 seconds that end at a pause, so words are rarely cut. Each chunk goes to a
/// `LiveChunkTranscriber`; in the app that's a helper process, so a crash in whisper.cpp can't end the recording. If a
/// chunk fails, live transcription stops and the Conversation is transcribed from its files instead.
public final class LiveTranscriber: @unchecked Sendable {
    static let shortestChunk = 20 * 16_000
    static let longestChunk = 30 * 16_000

    private let chunks: LiveChunkTranscriber
    private let onUpdate: @Sendable (Transcript) -> Void
    private let onFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "bekitzur.live-transcription", qos: .utility)
    private let timer: DispatchSourceTimer

    private let lock = NSLock()
    private var arrived: [[Float]]
    private var sampleRates: [Double?]

    // Only used on `queue`.
    private var language: ConversationLanguage
    private var converters: [AVAudioConverter?]
    private var converted: [Int]
    /// The mix from `mixStart` on, in samples from the start of the recording.
    private var mix: [Float] = []
    private var mixStart = 0
    private var segments: [TranscriptSegment] = []
    private var failed = false

    /// - Parameters:
    ///   - language: The Conversation's language, or the one to assume until the chunks' answers say which it is.
    ///   - onUpdate: The Transcript so far, whenever a chunk adds to it, on the transcription thread.
    ///   - onFailure: Live transcription has stopped, as when the helper process ended.
    public init(
        language: ConversationLanguage,
        chunks: LiveChunkTranscriber,
        tracks: Int,
        onUpdate: @escaping @Sendable (Transcript) -> Void,
        onFailure: @escaping @Sendable () -> Void = {}
    ) {
        self.language = language
        self.chunks = chunks
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        arrived = Array(repeating: [], count: tracks)
        sampleRates = Array(repeating: nil, count: tracks)
        converters = Array(repeating: nil, count: tracks)
        converted = Array(repeating: 0, count: tracks)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.step(final: false) }
        timer.resume()
    }

    /// Copies a track's samples; called on the recorder's audio thread.
    public func receive(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, track: Int) {
        lock.lock()
        sampleRates[track] = sampleRate
        arrived[track].append(contentsOf: samples)
        lock.unlock()
    }

    /// Transcribes the rest once the recording has stopped. Nil if live transcription failed along the way.
    public func finish() async -> Transcript? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer.cancel()
                self.step(final: true)
                self.chunks.finish {
                    self.queue.async {
                        continuation.resume(returning: self.failed ? nil : Transcript(language: self.language, segments: self.segments))
                    }
                }
            }
        }
    }

    /// Stops without transcribing the rest, as when the app quits while recording.
    public func cancel() {
        queue.async { self.timer.cancel() }
        chunks.cancel()
    }

    private func step(final: Bool) {
        guard !failed else { return }
        lock.lock()
        let batches = arrived, rates = sampleRates
        for track in arrived.indices { arrived[track].removeAll(keepingCapacity: true) }
        lock.unlock()
        for (track, batch) in batches.enumerated() {
            guard let rate = rates[track] else { continue }
            add(resampled(batch, from: rate, track: track, final: final), track: track)
        }
        let end = final ? converted.max() ?? 0 : ready
        while !failed, end > mixStart, let cut = Self.cut(mix[0..<(end - mixStart)], final: final), cut > 0 {
            send(count: cut)
        }
    }

    /// Up to where every track has arrived; a track more than 3 seconds behind the others counts as silence.
    private var ready: Int {
        guard let longest = converted.max(), let shortest = converted.min() else { return 0 }
        return max(shortest, longest - 3 * 16_000)
    }

    private func add(_ samples: [Float], track: Int) {
        let start = converted[track]
        converted[track] += samples.count
        let end = converted[track]
        if end - mixStart > mix.count { mix += [Float](repeating: 0, count: end - mixStart - mix.count) }
        for (i, sample) in samples.enumerated() where start + i >= mixStart {
            mix[start + i - mixStart] += sample
        }
    }

    /// The samples at 16 kHz, with the same converter settings as `AudioLoader`; the converter keeps its state between
    /// calls, and flushes what it holds when the recording has stopped.
    private func resampled(_ samples: [Float], from rate: Double, track: Int, final: Bool) -> [Float] {
        if rate == AudioLoader.sampleRate { return samples }
        if converters[track] == nil,
           let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
           let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioLoader.sampleRate, channels: 1, interleaved: false),
           let converter = AVAudioConverter(from: source, to: target) {
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converters[track] = converter
        }
        guard let converter = converters[track],
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        if let channel = input.floatChannelData?[0], !samples.isEmpty {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        var output: [Float] = []
        var given = samples.isEmpty
        let capacity = AVAudioFrameCount(Double(samples.count) * AudioLoader.sampleRate / rate) + 4_096
        while let buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = final ? .endOfStream : .noDataNow
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            if let data = buffer.floatChannelData, buffer.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            guard status == .haveData, buffer.frameLength > 0 else { break }
        }
        return output
    }

    /// Sends the first `count` samples of the mix to be transcribed, and drops them from the mix.
    private func send(count: Int) {
        let chunk = Array(mix[0..<count])
        let offset = Double(mixStart) / AudioLoader.sampleRate
        mix.removeFirst(count)
        mixStart += count
        chunks.transcribe(chunk, at: offset) { [self] found, language in
            queue.async { self.received(found, in: language) }
        }
    }

    private func received(_ found: [TranscriptSegment]?, in language: ConversationLanguage?) {
        guard !failed else { return }
        guard let found else {
            failed = true
            onFailure()
            return
        }
        if let language { self.language = language }
        guard !found.isEmpty else { return }
        segments += found
        onUpdate(Transcript(language: self.language, segments: segments))
    }

    /// Where to end a chunk that starts at the beginning of `samples` (16 kHz): in the middle of the quietest 0.4 seconds
    /// between 20 and 30 seconds in, as soon as that's a clear pause, or at 30 seconds whatever it is. Nil to wait for
    /// more audio. Once the recording has stopped, a remainder of up to 30 seconds is the last chunk.
    static func cut(_ samples: ArraySlice<Float>, final: Bool) -> Int? {
        if final, samples.count <= longestChunk { return samples.count }
        guard samples.count >= shortestChunk else { return nil }
        let frame = 320, window = 20
        let span = min(samples.count, longestChunk)
        var levels: [Float] = []
        levels.reserveCapacity(span / frame)
        var index = samples.startIndex
        while index + frame <= samples.startIndex + span {
            var power: Float = 0
            for i in index..<(index + frame) { power += samples[i] * samples[i] }
            levels.append((power / Float(frame)).squareRoot())
            index += frame
        }
        guard levels.count >= window else { return nil }
        var sum = levels[0..<window].reduce(0, +)
        var quietest: (center: Int, level: Float)?
        for start in 0...(levels.count - window) {
            if start > 0 { sum += levels[start + window - 1] - levels[start - 1] }
            let center = start + window / 2, level = sum / Float(window)
            if center * frame >= shortestChunk, level < quietest?.level ?? .infinity { quietest = (center, level) }
        }
        guard let quietest else { return nil }
        let typical = levels.sorted()[levels.count / 2]
        guard quietest.level <= 0.35 * typical || samples.count >= longestChunk else { return nil }
        return quietest.center * frame
    }
}
