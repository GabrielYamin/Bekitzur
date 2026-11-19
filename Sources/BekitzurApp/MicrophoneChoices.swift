import BekitzurCapture
import SwiftUI

/// The microphones to pick from, for a Picker on `AppModel.microphoneUID`: the Mac's default, each one connected, and the
/// one chosen while it isn't connected.
@MainActor @ViewBuilder
func microphoneChoices(_ model: AppModel) -> some View {
    Text(macDefault(model)).tag(String?.none)
    ForEach(model.microphones) { device in
        Text(device.name).tag(Optional(device.id))
    }
    if let id = model.microphoneUID, !model.microphones.contains(where: { $0.id == id }) {
        Text("\(model.microphoneName ?? String(localized: "The microphone chosen")), not connected").tag(Optional(id))
    }
}

@MainActor
private func macDefault(_ model: AppModel) -> String {
    guard let microphone = model.defaultMicrophone else { return String(localized: "Mac's default") }
    return String(localized: "Mac's default (\(microphone.name))")
}

/// The microphones to switch to while one sends nothing; the recording switches as one is picked.
struct AnotherMicrophone: View {
    let model: AppModel

    var body: some View {
        Menu("Use Another Microphone") {
            Picker("Microphone", selection: Binding(get: { model.microphoneUID }, set: { model.microphoneUID = $0 })) {
                microphoneChoices(model)
            }
            .pickerStyle(.inline)
        }
        .fixedSize()
    }
}
