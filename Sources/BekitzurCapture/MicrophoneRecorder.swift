import AVFoundation
import CoreAudio
import Synchronization

/// Records a microphone, the one chosen or the Mac's default, to a mono file.
public final class MicrophoneRecorder: @unchecked Sendable {
    /// What happens to the microphone while it records, for the log, and for telling the user when it sends nothing.
    public enum Event: Sendable, Equatable {
        /// Recording from the device at this rate and number of channels: at the start, and again after a change of
        /// device or format, a switch of microphone, or starting it again from scratch.
        case started(sampleRate: Double, channels: Int)
        /// The device didn't settle after a change, so it couldn't start over; checking for silence takes it from there.
        case gaveUp
        /// No audio for this many seconds, so the microphone is started again from scratch.
        case rebuilding(after: Double)
        /// Still no audio after this many seconds.
        case silent(after: Double)
        /// Audio came again after this many seconds without.
        case hearing(after: Double)
    }

    /// Replaced when the microphone is started again from scratch; after `start`, only used on `restarts`.
    private var engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var configurationChanges: NSObjectProtocol?
    private var onEvent: (@Sendable (Event) -> Void)?
    private let restarts = DispatchQueue(label: "bekitzur.microphone-restarts")
    /// The restart waiting for the device to settle, how many tries it's at, and whether the recording has stopped; only
    /// used on `restarts`.
    private var pendingRestart: DispatchWorkItem?
    private var attempt = 0
    private var stopped = false
    /// Checks every second that audio still comes; only used on `restarts`.
    private var watch: DispatchSourceTimer?
    private var silence = MicrophoneSilence()
    /// The host time the last block came, or the recording started.
    private let lastAudio = Atomic<UInt64>(0)
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
    ///   - onEvent: Called on a queue of the recorder's own.
    public func start(
        writingTo url: URL,
        origin: UInt64? = nil,
        listener: AudioListener? = nil,
        device: String? = nil,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) throws {
        self.device = device
        self.onEvent = onEvent
        restarts.sync {
            stopped = false
            silence = MicrophoneSilence()
        }
        lastAudio.store(mach_absolute_time(), ordering: .relaxed)
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
        observeChanges()
        try engine.start()
        onEvent?(.started(sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        restarts.sync { watchForSilence() }
    }

    /// Records from another microphone from now on: its UID, or nil for the Mac's default. It takes a new engine: one
    /// told to use a device stays with it, and only a new one follows the Mac's default.
    public func use(device: String?) {
        restarts.async { [self] in
            guard !stopped, writer != nil else { return }
            self.device = device
            restart(attempt: 0, fresh: true)
        }
    }

    /// A change of input device, or of its format, stops the engine; the recording goes on from the new device.
    private func observeChanges() {
        configurationChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartWhenSettled()
        }
    }

    private func tap(into writer: AudioFileWriter) {
        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).channelCount > 0 else { return }
        // The tap takes the input's format as it is when installed: given one, it raises an exception if the device has
        // changed since it was read ("Failed to create tap due to format mismatch").
        let conversion = Conversion(to: writer.format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            self?.lastAudio.store(mach_absolute_time(), ordering: .relaxed)
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
    private func restartWhenSettled() {
        // Pointing the engine at a device is a change too: one during a restart under way keeps its count of tries, or a
        // device that never settles would be tried forever.
        restarts.async { [self] in scheduleRestart(attempt: pendingRestart == nil ? 0 : attempt) }
    }

    /// Only on `restarts`, so the silence check sees a restart waiting as soon as there is one.
    private func scheduleRestart(attempt: Int) {
        guard !stopped else { return }
        self.attempt = attempt
        pendingRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in self?.restart(attempt: attempt) }
        pendingRestart = restart
        restarts.asyncAfter(deadline: .now() + 0.3, execute: restart)
    }

    /// - Parameter fresh: Starts from a new engine, as after a switch of microphone or when the engine sends nothing.
    private func restart(attempt: Int, fresh: Bool = false) {
        pendingRestart?.cancel()
        pendingRestart = nil
        guard !stopped, let writer else { return }
        if fresh { replaceEngine() }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        useDevice()
        guard Self.isSettled(input) else {
            retry(after: attempt)
            return
        }
        writer.restarted()
        tap(into: writer)
        do {
            try engine.start()
            let format = input.outputFormat(forBus: 0)
            onEvent?(.started(sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        } catch {
            retry(after: attempt)
        }
    }

    private func retry(after attempt: Int) {
        if attempt < 20 {
            scheduleRestart(attempt: attempt + 1)
        } else {
            onEvent?(.gaveUp)
        }
    }

    private func replaceEngine() {
        if let configurationChanges { NotificationCenter.default.removeObserver(configurationChanges) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeChanges()
    }

    /// Only on `restarts`.
    private func watchForSilence() {
        let timer = DispatchSource.makeTimerSource(queue: restarts)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkSilence() }
        timer.resume()
        watch = timer
    }

    private func checkSilence() {
        guard !stopped, writer != nil else { return }
        let now = mach_absolute_time(), last = lastAudio.load(ordering: .relaxed)
        let quiet = now > last ? AVAudioTime.seconds(forHostTime: now - last) : 0
        for action in silence.check(quiet: quiet, now: AVAudioTime.seconds(forHostTime: now), restarting: pendingRestart != nil) {
            switch action {
            case .rebuild:
                onEvent?(.rebuilding(after: quiet))
                restart(attempt: 0, fresh: true)
            case .silent(let seconds):
                onEvent?(.silent(after: seconds))
            case .hearing(let seconds):
                onEvent?(.hearing(after: seconds))
            }
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
        restarts.sync {
            stopped = true
            pendingRestart?.cancel()
            pendingRestart = nil
            watch?.cancel()
            watch = nil
        }
        if let configurationChanges { NotificationCenter.default.removeObserver(configurationChanges) }
        configurationChanges = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let report = writer?.close()
        writer = nil
        return report
    }
}
