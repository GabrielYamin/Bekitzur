import BekitzurCapture
import SwiftUI

/// The microphones to pick from, for a Picker on `AppModel.microphoneUID`: the Mac's default, each one connected, and the
/// one chosen while it isn't connected.
@MainActor @ViewBuilder
func microphoneChoices(_ model: AppModel) -> some View {
    Text(model.defaultMicrophone.map { "Mac's default (\($0.name))" } ?? "Mac's default").tag(String?.none)
    ForEach(model.microphones) { device in
        Text(device.name).tag(Optional(device.id))
    }
    if let id = model.microphoneUID, !model.microphones.contains(where: { $0.id == id }) {
        Text("\(model.microphoneName ?? "The microphone chosen"), not connected").tag(Optional(id))
    }
}
