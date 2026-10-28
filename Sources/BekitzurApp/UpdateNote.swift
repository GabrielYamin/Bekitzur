import SwiftUI

/// A newer version is out, with the button that installs it (after asking); nothing when there's none.
struct UpdateNote: View {
    let model: AppModel

    var body: some View {
        if let update = model.availableUpdate {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text(model.updateStep ?? "Bekitzur \(update.version) is available.").font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.updateStep == nil {
                    Button("Install…") { model.installUpdate(update) }.controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
