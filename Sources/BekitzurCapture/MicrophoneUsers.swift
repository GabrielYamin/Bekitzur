import CoreAudio
import Foundation

/// The apps using the microphone, by bundle ID, from Core Audio's list of the processes doing audio, told whenever it
/// changes. Bekitzur itself isn't one of them. Reading the list asks for no permission.
///
/// A process starting or stopping to use the microphone sends no notice; only the list changing does, when a process
/// connects to audio, and Slack's helpers stay connected between calls. So the list is read every second while any
/// microphone is in use, which each input device notices, including while Bekitzur records and keeps one in use itself.
@MainActor
public final class MicrophoneUsers {
    public private(set) var bundleIDs: [String] = []
    private let changed: ([String]) -> Void
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// A listener on whether each device with an input is in use by any process.
    private var runningListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?

    public init(changed: @escaping ([String]) -> Void) {
        self.changed = changed
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard devicesListener == nil else { return }
        var devices = Self.address(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.listenToInputDevices() } }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listener) == noErr else { return }
        devicesListener = listener
        listenToInputDevices()
    }

    public func stop() {
        if let devicesListener {
            var devices = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, devicesListener)
        }
        devicesListener = nil
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for (device, listener) in runningListeners {
            AudioObjectRemovePropertyListenerBlock(device, &running, .main, listener)
        }
        runningListeners = [:]
        timer?.invalidate()
        timer = nil
        bundleIDs = []
    }

    /// Listens to each device with an input, as devices come and go.
    private func listenToInputDevices() {
        let inputs = Self.devices().filter(Self.hasInput)
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for device in inputs where runningListeners[device] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.inputUseChanged() } }
            if AudioObjectAddPropertyListenerBlock(device, &running, .main, listener) == noErr { runningListeners[device] = listener }
        }
        for (device, listener) in runningListeners where !inputs.contains(device) {
            AudioObjectRemovePropertyListenerBlock(device, &running, .main, listener)
            runningListeners[device] = nil
        }
        inputUseChanged()
    }

    /// Reads the list now, and every second while any microphone is in use.
    private func inputUseChanged() {
        refresh()
        let inUse = runningListeners.keys.contains { Self.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 }
        if inUse, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        } else if !inUse {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refresh() {
        let own = ProcessInfo.processInfo.processIdentifier
        let using = Self.processes()
            .filter { Self.uint32($0, kAudioProcessPropertyIsRunningInput) == 1 && Self.uint32($0, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } != own }
            .compactMap { Self.string($0, kAudioProcessPropertyBundleID) }
            .filter { !$0.isEmpty }
            .sorted()
        guard using != bundleIDs else { return }
        bundleIDs = using
        changed(using)
    }

    private static func processes() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyProcessObjectList)
    }

    private static func devices() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyDevices)
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
