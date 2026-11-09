import AVFoundation
import CoreAudio

/// Records a microphone, the one chosen or the Mac's default, to a mono file.
public final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var configurationChanges: NSObjectProtocol?
    private let restarts = DispatchQueue(label: "bekitzur.microphone-restarts")
    /// The restart waiting for the device to settle, and whether the recording has stopped; only used on `restarts`.
    private var pendingRestart: DispatchWorkItem?
    private var stopped = false
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
        restarts.sync { stopped = false }
        useDevice()
        // A microphone in the middle of a change, as a Bluetooth headset connecting, has no format to record in yet.
        var waited = 0
        while !Self.isSettled(engine.inputNode), waited < 20 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard Self.isSettled(engine.inputNode), let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw CaptureError(step: "find a microphone", status: kAudioHardwareBadDeviceError)
        }
        let writer = try AudioFileWriter(url: url, format: mono, origin: origin, listener: listener)
        self.writer = writer
        tap(into: writer)
        // A change of input device, or of its format, stops the engine; the recording goes on from the new device.
        configurationChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartWhenSettled()
        }
        try engine.start()
    }

    private func tap(into writer: AudioFileWriter) {
        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).channelCount > 0 else { return }
        // The tap takes the input's format as it is when installed: given one, it raises an exception if the device has
        // changed since it was read ("Failed to create tap due to format mismatch").
        let conversion = Conversion(to: writer.format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
            let hostTime = when.isHostTimeValid ? when.hostTime : nil
            if let converter = conversion.converter(for: buffer.format) {
                if let converted = Self.convert(buffer, with: converter) { writer.write(converted, at: hostTime) }
            } else {
                writer.write(buffer, at: hostTime, sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : nil)
            }
        }
    }

    /// Converts a device's blocks at another rate than the file's, which are then placed by when they were captured,
    /// since the converter's blocks don't follow the device's count.
    private final class Conversion: @unchecked Sendable {
        private let rate: Double
        private var current: AVAudioConverter?

        init(to rate: Double) {
            self.rate = rate
        }

        /// Nil for blocks at the file's rate. Called on the tap's thread only.
        func converter(for format: AVAudioFormat) -> AVAudioConverter? {
            guard format.sampleRate != rate else { return nil }
            if let current, current.inputFormat == format { return current }
            current = AVAudioFormat(standardFormatWithSampleRate: rate, channels: format.channelCount).flatMap { AVAudioConverter(from: format, to: $0) }
            return current
        }
    }

    /// Points the engine's input at the chosen microphone, or at the default one once it's disconnected.
    private func useDevice() {
        guard let device, let unit = engine.inputNode.audioUnit else { return }
        guard var id = AudioInputDevice.objectID(forUID: device) ?? AudioInputDevice.defaultObjectID() else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    /// Restarts on the device in use once it has gone 0.3 seconds without another change, and again while its format
    /// isn't settled: a Bluetooth headset changes format in steps as a call app takes its microphone, and a tap installed
    /// in a format the device has just left raises an exception, which ends the app.
    private func restartWhenSettled(attempt: Int = 0) {
        restarts.async { [self] in
            guard !stopped else { return }
            pendingRestart?.cancel()
            let restart = DispatchWorkItem { [weak self] in self?.restart(attempt: attempt) }
            pendingRestart = restart
            restarts.asyncAfter(deadline: .now() + 0.3, execute: restart)
        }
    }

    private func restart(attempt: Int) {
        guard !stopped, let writer else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        useDevice()
        guard Self.isSettled(input) else {
            if attempt < 20 { restartWhenSettled(attempt: attempt + 1) }
            return
        }
        writer.restarted()
        tap(into: writer)
        do {
            try engine.start()
        } catch {
            if attempt < 20 { restartWhenSettled(attempt: attempt + 1) }
        }
    }

    private static func isSettled(_ input: AVAudioInputNode) -> Bool {
        canTap(input.outputFormat(forBus: 0), hardware: input.inputFormat(forBus: 0))
    }

    /// Whether a tap can be installed in the input's format: during a change, a device can have no channels or rate, or
    /// a rate its hardware has already left.
    static func canTap(_ format: AVAudioFormat, hardware: AVAudioFormat) -> Bool {
        guard format.channelCount > 0, format.sampleRate > 0 else { return false }
        return format.sampleRate == hardware.sampleRate
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
        restarts.sync {
            stopped = true
            pendingRestart?.cancel()
            pendingRestart = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let report = writer?.close()
        writer = nil
        return report
    }
}
