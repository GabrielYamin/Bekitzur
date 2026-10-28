import AVFoundation
import CoreAudio

/// Receives what's recorded, mixed down to mono, with its sample rate, on the recorder's audio thread. The samples are
/// only valid during the call, so a listener copies what it needs and returns.
public typealias AudioListener = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void

/// Writes audio buffers from an audio thread to a compressed file.
///
/// Each recorder writes from a single audio thread, so the file is never written concurrently.
final class AudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let tail: UnsafeMutableAudioBufferListPointer
    private let listener: AudioListener?
    private let origin: UInt64?
    private var mono: [Float] = []
    /// Seconds of silence the file starts with, set by the first write.
    private(set) var leadingSilence: Double?

    /// Buffers in `format` are written as they are; buffers with more channels are mixed down first. The listener gets
    /// each buffer after it's written.
    /// - Parameter origin: The host time the recording started, shared by its tracks. The file starts with silence up to
    ///   the moment its first buffer was captured, so tracks whose devices start at different times line up.
    init(url: URL, format: AVAudioFormat, origin: UInt64? = nil, listener: AudioListener? = nil) throws {
        self.listener = listener
        self.origin = origin
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        // AAC's highest bit rate shrinks with the sample rate; below 32 kHz the encoder's default is safe.
        if format.sampleRate >= 32_000 { settings[AVEncoderBitRateKey] = 64_000 * Int(format.channelCount) }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.format = format
        tail = AudioBufferList.allocate(maximumBuffers: format.isInterleaved ? 1 : Int(format.channelCount))
    }

    deinit {
        free(tail.unsafeMutablePointer)
    }

    /// - Parameter hostTime: When the buffer's first frame was captured.
    func write(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64? = nil) {
        guard let buffer = buffer.format.channelCount == format.channelCount ? buffer : mixedDown(buffer) else { return }
        if leadingSilence == nil { fillToOrigin(before: hostTime) }
        try? file.write(from: buffer)
        if let listener { hear(buffer, listener) }
    }

    private func fillToOrigin(before hostTime: UInt64?) {
        leadingSilence = 0
        guard let origin, let hostTime, hostTime > origin else { return }
        let seconds = AVAudioTime.seconds(forHostTime: hostTime - origin)
        let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        leadingSilence = Double(frames) / format.sampleRate
        try? file.write(from: silence)
        if let listener { hear(silence, listener) }
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

    /// Writes the last streams of an audio device's input. An aggregate device lists the inputs of its sub-devices
    /// (a headset's microphone, say) before the tap's streams.
    func write(_ bufferList: UnsafePointer<AudioBufferList>, at hostTime: UInt64? = nil) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard input.count >= tail.count else { return }
        for i in 0..<tail.count {
            tail[i] = input[input.count - tail.count + i]
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tail.unsafePointer, deallocator: nil) else { return }
        write(buffer, at: hostTime)
    }

    /// Finishes the file. Call after the audio thread has stopped; later writes are dropped.
    func close() {
        file.close()
    }

    private func mixedDown(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard format.channelCount == 1, !format.isInterleaved, let channels = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        for i in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][i] }
            output[i] = sum / Float(channelCount)
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}
