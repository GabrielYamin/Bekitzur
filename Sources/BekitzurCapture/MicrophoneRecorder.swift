import AVFoundation
import CoreAudio

/// Records the default input device to a mono file.
public final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?

    public init() {}

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static var permission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    /// - Parameter origin: The host time the recording started; the file starts with silence up to the first sound.
    public func start(writingTo url: URL, origin: UInt64? = nil, listener: AudioListener? = nil) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw CaptureError(step: "find a microphone", status: kAudioHardwareBadDeviceError)
        }
        let writer = try AudioFileWriter(url: url, format: mono, origin: origin, listener: listener)
        self.writer = writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            writer.write(buffer, at: when.isHostTimeValid ? when.hostTime : nil)
        }
        try engine.start()
    }

    /// Seconds of silence the file started with, once the first sound arrived.
    var leadingSilence: Double? { writer?.leadingSilence }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
    }
}
