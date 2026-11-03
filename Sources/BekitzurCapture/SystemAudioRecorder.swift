import AVFoundation
import CoreAudio

public struct CaptureError: Error, CustomStringConvertible {
    public let step: String
    public let status: OSStatus

    public var description: String { "Couldn't \(step) (Core Audio error \(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw CaptureError(step: step, status: status) }
}

/// Records everything the Mac plays (Teams, Slack, a Continuity call) with a Core Audio process tap.
///
/// A tap needs only the "System Audio Recording Only" permission, not screen recording. If the user denies it,
/// the tap still runs but delivers silence.
public final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private let queue = DispatchQueue(label: "bekitzur.system-audio", qos: .userInitiated)
    private let overloads = Overloads()
    private var overloadListener: AudioObjectPropertyListenerBlock?

    /// Times Core Audio couldn't hand the recording a block in time, counted on Core Audio's notification queue.
    private final class Overloads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func add() {
            lock.withLock { count += 1 }
        }

        var total: Int { lock.withLock { count } }
    }

    private static var overloadAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    public init() {}

    /// The recording device's name: it has inputs, the tap's, but isn't a microphone to choose.
    static let deviceName = "Bekitzur Recording"

    /// - Parameter origin: The host time the recording started; the file starts with silence up to the first sound.
    public func start(writingTo url: URL, origin: UInt64? = nil, listener: AudioListener? = nil) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "Bekitzur"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create the system audio tap")

        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description), "read the system audio format")

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the recording device")

        // Drift compensation resamples the tap to the aggregate device's clock, which follows the output device.
        var sampleRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &sampleRate) == noErr, sampleRate > 0 {
            description.mSampleRate = sampleRate
        }
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw CaptureError(step: "use the system audio format", status: kAudioHardwareUnsupportedOperationError)
        }

        let writer = try AudioFileWriter(url: url, format: format, origin: origin, listener: listener)
        self.writer = writer
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
                let time = inputTime.pointee
                writer.write(
                    input,
                    at: time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil,
                    sampleTime: time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : nil
                )
            },
            "receive system audio"
        )
        let overloads = overloads
        let overloaded: AudioObjectPropertyListenerBlock = { _, _ in overloads.add() }
        var overloadAddress = Self.overloadAddress
        if AudioObjectAddPropertyListenerBlock(aggregateID, &overloadAddress, queue, overloaded) == noErr { overloadListener = overloaded }
        try check(AudioDeviceStart(aggregateID, procID), "start recording system audio")
    }

    /// Stops and finishes the file; nil if it wasn't recording.
    @discardableResult
    public func stop() -> TrackReport? {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if let overloadListener {
            var address = Self.overloadAddress
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, queue, overloadListener)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        overloadListener = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        var report = writer?.close()
        report?.overloads = overloads.total
        writer = nil
        return report
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "find the output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "read the output device")
        guard let value = uid?.takeRetainedValue() else {
            throw CaptureError(step: "read the output device", status: kAudioHardwareUnspecifiedError)
        }
        return value as String
    }
}
