import CoreAudio
import Foundation

/// The apps using the microphone, by bundle ID, from Core Audio's list of the processes doing audio, told whenever it
/// changes. Bekitzur itself isn't one of them. Reading the list asks for no permission.
@MainActor
public final class MicrophoneUsers {
    public private(set) var bundleIDs: [String] = []
    private let changed: ([String]) -> Void
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// A listener on each process's use of the microphone, since the process list doesn't change when it starts.
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    public init(changed: @escaping ([String]) -> Void) {
        self.changed = changed
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard processListListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let listener = listener()
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        processListListener = listener
        refresh()
    }

    public func stop() {
        if let processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, processListListener)
        }
        processListListener = nil
        var input = Self.address(kAudioProcessPropertyIsRunningInput)
        for (process, listener) in inputListeners {
            AudioObjectRemovePropertyListenerBlock(process, &input, .main, listener)
        }
        inputListeners = [:]
        bundleIDs = []
    }

    private func listener() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    private func refresh() {
        let processes = Self.processes()
        var input = Self.address(kAudioProcessPropertyIsRunningInput)
        for process in processes where inputListeners[process] == nil {
            let listener = listener()
            if AudioObjectAddPropertyListenerBlock(process, &input, .main, listener) == noErr { inputListeners[process] = listener }
        }
        for (process, listener) in inputListeners where !processes.contains(process) {
            AudioObjectRemovePropertyListenerBlock(process, &input, .main, listener)
            inputListeners[process] = nil
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let using = processes
            .filter { Self.uint32($0, kAudioProcessPropertyIsRunningInput) == 1 && Self.uint32($0, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } != own }
            .compactMap { Self.string($0, kAudioProcessPropertyBundleID) }
            .filter { !$0.isEmpty }
            .sorted()
        guard using != bundleIDs else { return }
        bundleIDs = using
        changed(using)
    }

    private static func processes() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return [] }
        return Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
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
