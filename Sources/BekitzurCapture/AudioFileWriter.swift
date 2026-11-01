import AVFoundation
import CoreAudio
import Synchronization

/// Receives what's recorded, mixed down to mono, with its sample rate, on the writing thread. The samples are only
/// valid during the call, so a listener copies what it needs and returns.
public typealias AudioListener = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void

/// How a track kept time while it was recorded.
public struct TrackReport: Sendable {
    /// Seconds of silence the file starts with: how long its device took to deliver the first sound.
    public var leadingSilence = 0.0
    /// Times audio went missing on the way, as when the Mac was too busy to take a block in time.
    public var gaps = 0
    /// Seconds of silence written in place of what went missing, which kept the rest of the track in time.
    public var gapSeconds = 0.0
    /// Seconds that came while the writing thread was too far behind to keep them; part of the gaps.
    public var lostSeconds = 0.0
    /// Times Core Audio couldn't hand Bekitzur a block in time.
    public var overloads = 0
    /// Times the device started over, as after a change of device.
    public var restarts = 0
    /// Blocks the file couldn't take.
    public var failedWrites = 0
}

/// Writes a track to a compressed file, keeping it in time. On the device's thread a block is only copied into a ring;
/// a writing thread takes it out, places it by `TrackTimeline`, encodes it, and hands it to the listener. Encoding and
/// writing on the device's thread made Core Audio drop blocks whenever the Mac was busy, and every block dropped moved
/// the rest of the track earlier.
final class AudioFileWriter: @unchecked Sendable {
    let format: AVAudioFormat
    private let file: AVAudioFile
    private let ring: AudioRing
    private let channels: Int
    private let interleaved: Bool
    private let listener: AudioListener?
    private let queue = DispatchQueue(label: "bekitzur.audio-writer", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let restartPending = Atomic<Bool>(false)

    // Only used on `queue`.
    private var timeline: TrackTimeline
    private let staging: AVAudioPCMBuffer
    private let zeros: AVAudioPCMBuffer
    private var mono: [Float] = []
    private var failedWrites = 0
    private var closed = false

    /// Buffers in `format` are written as they are; buffers with more channels are mixed down first. The listener gets
    /// each buffer after it's written.
    /// - Parameters:
    ///   - origin: The host time the recording started, shared by its tracks. The file starts with silence up to the
    ///     moment its first buffer was captured, so tracks whose devices start at different times line up.
    ///   - buffering: Seconds the writing thread can fall behind before audio is lost.
    init(url: URL, format: AVAudioFormat, origin: UInt64? = nil, buffering: Double = 30, listener: AudioListener? = nil) throws {
        self.listener = listener
        self.format = format
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        // AAC's highest bit rate shrinks with the sample rate; below 32 kHz the encoder's default is safe.
        if format.sampleRate >= 32_000 { settings[AVEncoderBitRateKey] = 64_000 * Int(format.channelCount) }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        channels = Int(format.channelCount)
        interleaved = format.isInterleaved
        ring = AudioRing(
            channels: channels,
            interleaved: interleaved,
            sampleRate: format.sampleRate,
            seconds: buffering,
            ticksPerSecond: Double(AVAudioTime.hostTime(forSeconds: 1))
        )
        guard let staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ring.slotFrames)),
              let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw CaptureError(step: "make room for the recording", status: kAudioHardwareUnspecifiedError)
        }
        zeros.frameLength = zeros.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        self.staging = staging
        self.zeros = zeros
        timeline = TrackTimeline(sampleRate: format.sampleRate, origin: origin)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    /// Copies a buffer in, mixed down to mono for a mono file. Call from the device's thread only.
    /// - Parameters:
    ///   - hostTime: When its first frame was captured.
    ///   - sampleTime: The device's count of its first frame.
    func write(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64? = nil, sampleTime: Double? = nil) {
        guard let source = buffer.floatChannelData else { return }
        let sourceChannels = Int(buffer.format.channelCount), sourceInterleaved = buffer.format.isInterleaved
        guard sourceChannels == channels || channels == 1 else { return }
        let channels = channels, interleaved = interleaved, slotFrames = ring.slotFrames
        let sample = { (channel: Int, frame: Int) in sourceInterleaved ? source[0][frame * sourceChannels + channel] : source[channel][frame] }
        put(frames: Int(buffer.frameLength), hostTime: hostTime, sampleTime: sampleTime) { slot, offset, count in
            if channels == 1, sourceChannels > 1 {
                for i in 0..<count {
                    var sum: Float = 0
                    for channel in 0..<sourceChannels { sum += sample(channel, offset + i) }
                    slot[i] = sum / Float(sourceChannels)
                }
            } else if interleaved {
                for i in 0..<count {
                    for channel in 0..<channels { slot[i * channels + channel] = sample(channel, offset + i) }
                }
            } else {
                for channel in 0..<channels {
                    for i in 0..<count { slot[channel * slotFrames + i] = sample(channel, offset + i) }
                }
            }
        }
    }

    /// Copies in the last streams of an audio device's input. An aggregate device lists the inputs of its sub-devices
    /// (a headset's microphone, say) before the tap's streams. Call from the device's thread only.
    func write(_ bufferList: UnsafePointer<AudioBufferList>, at hostTime: UInt64? = nil, sampleTime: Double? = nil) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let streams = interleaved ? 1 : channels
        guard input.count >= streams else { return }
        let first = input.count - streams
        let channels = channels, interleaved = interleaved, slotFrames = ring.slotFrames
        let frames = Int(input[first].mDataByteSize) / (MemoryLayout<Float>.size * (interleaved ? channels : 1))
        for stream in first..<input.count where input[stream].mData == nil { return }
        put(frames: frames, hostTime: hostTime, sampleTime: sampleTime) { slot, offset, count in
            if interleaved {
                let source = input[first].mData!.assumingMemoryBound(to: Float.self)
                slot.update(from: source + offset * channels, count: count * channels)
            } else {
                for channel in 0..<channels {
                    let source = input[first + channel].mData!.assumingMemoryBound(to: Float.self)
                    (slot + channel * slotFrames).update(from: source + offset, count: count)
                }
            }
        }
    }

    /// The device started over, as after a change of device: its next block is placed by when it was captured.
    func restarted() {
        restartPending.store(true, ordering: .releasing)
    }

    private func put(frames: Int, hostTime: UInt64?, sampleTime: Double?, copy: (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        guard frames > 0 else { return }
        let restarted = restartPending.exchange(false, ordering: .acquiringAndReleasing)
        ring.put(frames: frames, sampleTime: sampleTime ?? .nan, hostTime: hostTime ?? 0, restarted: restarted, copy: copy)
    }

    /// Writes what's arrived so far. Tests call it to see the file and the listener catch up.
    func flush() {
        queue.sync { drain() }
    }

    /// Writes what's left and finishes the file. Call after the device has stopped; later blocks are dropped.
    @discardableResult
    func close() -> TrackReport {
        queue.sync {
            if !closed {
                timer.cancel()
                drain()
                file.close()
                closed = true
            }
            return report
        }
    }

    /// Seconds of silence the file started with, once the first block is written.
    var leadingSilence: Double? {
        queue.sync { timeline.leadingSilence }
    }

    private var report: TrackReport {
        TrackReport(
            leadingSilence: timeline.leadingSilence ?? 0,
            gaps: timeline.gaps,
            gapSeconds: Double(timeline.silenceFrames) / format.sampleRate,
            lostSeconds: Double(ring.lost) / format.sampleRate,
            restarts: timeline.restarts,
            failedWrites: failedWrites
        )
    }

    private func drain() {
        guard !closed else { return }
        ring.take { block, slot in
            let (silence, skip) = timeline.place(frames: block.frames, sampleTime: block.sampleTime, hostTime: block.hostTime, restarted: block.restarted)
            var left = silence
            while left > 0 {
                zeros.frameLength = AVAudioFrameCount(min(left, Int(zeros.frameCapacity)))
                write(zeros)
                left -= Int(zeros.frameLength)
            }
            let count = block.frames - skip
            guard count > 0, let target = staging.floatChannelData else { return }
            if interleaved {
                target[0].update(from: slot + skip * channels, count: count * channels)
            } else {
                for channel in 0..<channels { target[channel].update(from: slot + channel * ring.slotFrames + skip, count: count) }
            }
            staging.frameLength = AVAudioFrameCount(count)
            write(staging)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
        } catch {
            failedWrites += 1
        }
        if let listener { hear(buffer, listener) }
    }

    /// The buffer as mono, averaging its channels into storage reused from call to call.
    private func hear(_ buffer: AVAudioPCMBuffer, _ listener: AudioListener) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            listener(UnsafeBufferPointer(start: channels[0], count: frames), format.sampleRate)
            return
        }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        let interleaved = buffer.format.isInterleaved
        mono.withUnsafeMutableBufferPointer { output in
            for i in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += interleaved ? channels[0][i * channelCount + channel] : channels[channel][i] }
                output[i] = sum / Float(channelCount)
            }
            listener(UnsafeBufferPointer(rebasing: output[0..<frames]), format.sampleRate)
        }
    }
}
