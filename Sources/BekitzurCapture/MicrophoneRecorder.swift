import AVFoundation
import CoreAudio

/// Records a microphone, the one chosen or the Mac's default, to a mono file.
public final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var configurationChanges: NSObjectProtocol?
    private let restarts = DispatchQueue(label: "bekitzur.microphone-restarts")
    /// The chosen microphone's UID; nil for the Mac's default, which the engine follows by itself.
    private var device: String?

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

    /// - Parameters:
    ///   - origin: The host time the recording started; the file starts with silence up to the first sound.
    ///   - device: The UID of the microphone to record (`AudioInputDevice`); nil for the Mac's default.
    public func start(writingTo url: URL, origin: UInt64? = nil, listener: AudioListener? = nil, device: String? = nil) throws {
        self.device = device
        useDevice()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw CaptureError(step: "find a microphone", status: kAudioHardwareBadDeviceError)
        }
        let writer = try AudioFileWriter(url: url, format: mono, origin: origin, listener: listener)
        self.writer = writer
        tap(into: writer)
        // A change of input device, or of its format, stops the engine; the recording goes on from the new device.
        configurationChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            restarts.async { self.restart() }
        }
        try engine.start()
    }

    private func tap(into writer: AudioFileWriter) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        // A device at another rate than the file's is converted, and its blocks are placed by when they were captured,
        // since the converter's blocks don't follow the device's count.
        let converter = format.sampleRate == writer.format.sampleRate ? nil : AVAudioFormat(
            standardFormatWithSampleRate: writer.format.sampleRate,
            channels: format.channelCount
        ).flatMap { AVAudioConverter(from: format, to: $0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let hostTime = when.isHostTimeValid ? when.hostTime : nil
            if let converter {
                if let converted = Self.convert(buffer, with: converter) { writer.write(converted, at: hostTime) }
            } else {
                writer.write(buffer, at: hostTime, sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : nil)
            }
        }
    }

    /// Points the engine's input at the chosen microphone, or at the default one once it's disconnected.
    private func useDevice() {
        guard let device, let unit = engine.inputNode.audioUnit else { return }
        guard var id = AudioInputDevice.objectID(forUID: device) ?? AudioInputDevice.defaultObjectID() else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    private func restart() {
        guard let writer else { return }
        engine.inputNode.removeTap(onBus: 0)
        useDevice()
        writer.restarted()
        tap(into: writer)
        try? engine.start()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else {
            return nil
        }
        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return output.frameLength > 0 ? output : nil
    }

    /// Stops and finishes the file; nil if it wasn't recording.
    @discardableResult
    public func stop() -> TrackReport? {
        if let configurationChanges { NotificationCenter.default.removeObserver(configurationChanges) }
        configurationChanges = nil
        restarts.sync {}
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let report = writer?.close()
        writer = nil
        return report
    }
}
