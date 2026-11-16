import SwiftUI

/// The models Bekitzur still needs, with the button that downloads them and the download's progress; nothing once
/// they're all in.
struct ModelsNote: View {
    let model: AppModel

    var body: some View {
        if case .tooLow = model.memory {
            // RequirementsNote says why there's nothing to download.
            EmptyView()
        } else if let download = model.modelDownload {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = download.failure {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Try Again") { model.downloadModels() }.controlSize(.small).hoverLight()
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(download.step)…").font(.callout)
                        Spacer(minLength: 0)
                        Button("Stop") { model.stopModelDownload() }.controlSize(.small).hoverLight()
                    }
                    ProgressView(value: Double(download.received), total: Double(max(download.total, 1)))
                    Text("\(download.received.formatted(.byteCount(style: .file))) of \(download.total.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        } else if !model.missingModels.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text(model.modelsMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Download") { model.downloadModels() }.controlSize(.small).hoverLight()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
