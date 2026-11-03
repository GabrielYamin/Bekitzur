import CoreAudio
import Foundation

/// A microphone the Mac has: built in, a headset, a USB microphone, or one an app adds, like a call app's.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// Core Audio's UID, which stays the same across launches and reconnections, unlike the device's object ID.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The microphones connected now, by name. Virtual devices and aggregates aren't microphones: Teams and Zoom each add
    /// one to send a Mac's sound into a call, which recorded silence or the app's own sound, and Bekitzur's recording
    /// device is one.
    public static func all() -> [AudioInputDevice] {
        deviceIDs()
            .compactMap { device -> AudioInputDevice? in
                guard inputChannels(of: device) > 0,
                      ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate].contains(transportType(of: device)),
                      let id = string(kAudioDevicePropertyDeviceUID, of: device),
                      let name = string(kAudioObjectPropertyName, of: device),
                      name != SystemAudioRecorder.deviceName
                else { return nil }
                return AudioInputDevice(id: id, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func transportType(of device: AudioObjectID) -> UInt32 {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr ? transport : 0
    }

    /// The one macOS records from unless told otherwise (System Settings → Sound → Input).
    public static var systemDefault: AudioInputDevice? {
        guard let device = defaultObjectID(),
              let id = string(kAudioDevicePropertyDeviceUID, of: device),
              let name = string(kAudioObjectPropertyName, of: device)
        else { return nil }
        return AudioInputDevice(id: id, name: name)
    }

    /// `id` when that microphone is connected among `devices`; nil, for the Mac's default, otherwise.
    public static func connected(_ id: String?, among devices: [AudioInputDevice]) -> String? {
        devices.contains { $0.id == id } ? id : nil
    }

    static func objectID(forUID id: String) -> AudioObjectID? {
        deviceIDs().first { string(kAudioDevicePropertyDeviceUID, of: $0) == id }
    }

    static func defaultObjectID() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannels(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    fileprivate static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Calls back on the main queue when a microphone is connected or disconnected, or the Mac's default one changes, for
/// as long as it's kept.
public final class AudioInputWatch: @unchecked Sendable {
    private let listener: AudioObjectPropertyListenerBlock
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    public init(_ changed: @escaping @Sendable () -> Void) {
        listener = { _, _ in changed() }
        for selector in Self.selectors {
            var address = AudioInputDevice.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = AudioInputDevice.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
}
