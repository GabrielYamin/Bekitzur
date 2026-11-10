import SwiftUI

/// A newer version is out, with the button that installs it (after asking), and how far its download has come; nothing
/// when there's none. With only a spinner, Install would seem to have done nothing.
struct UpdateNote: View {
    let model: AppModel

    var body: some View {
        if let update = model.availableUpdate {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(status(version: update.version)).font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.updateStep == nil {
                        Button("Install…") { model.installUpdate(update) }
                            .controlSize(.small)
                            .hoverLight()
                    } else if model.updateProgress == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if let progress = model.updateProgress {
                    ProgressView(value: progress)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func status(version: String) -> String {
        guard let step = model.updateStep else { return String(localized: "Bekitzur \(version) is available.") }
        guard let progress = model.updateProgress else { return step }
        return "\(step) \(Int((progress * 100).rounded()))%"
    }
}
