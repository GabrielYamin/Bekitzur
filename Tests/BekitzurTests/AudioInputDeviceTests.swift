import BekitzurCapture
import Testing

struct AudioInputDeviceTests {
    private let devices = [AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"), AudioInputDevice(id: "usb-1234", name: "USB Microphone")]

    @Test func theChosenMicrophoneIsRecordedOnlyWhileItsConnected() {
        #expect(AudioInputDevice.connected("usb-1234", among: devices) == "usb-1234")
        #expect(AudioInputDevice.connected("headset-unplugged", among: devices) == nil)
        #expect(AudioInputDevice.connected(nil, among: devices) == nil)
    }

    @Test func bekitzursOwnRecordingDeviceIsntOneToPick() {
        #expect(!AudioInputDevice.all().contains { $0.name == "Bekitzur Recording" })
    }
}
