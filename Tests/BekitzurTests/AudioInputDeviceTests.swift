import BekitzurCapture
import Testing

struct AudioInputDeviceTests {
    private let devices = [AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"), AudioInputDevice(id: "usb-1234", name: "USB Microphone")]

    /// Nothing here asks the Mac for its microphones: on GitHub's macOS runner, which has no audio hardware, a test that
    /// did kept the release build from finishing.
    @Test func theChosenMicrophoneIsRecordedOnlyWhileItsConnected() {
        #expect(AudioInputDevice.connected("usb-1234", among: devices) == "usb-1234")
        #expect(AudioInputDevice.connected("headset-unplugged", among: devices) == nil)
        #expect(AudioInputDevice.connected(nil, among: devices) == nil)
    }
}
