import BekitzurModels
import SwiftUI

/// What this Mac lacks that Bekitzur needs: memory below the 32 GB it's made for. Under 24 GB it takes the place of the
/// models' note, since the models aren't downloaded; between 24 and 32 GB it says so once, until OK.
struct RequirementsNote: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.memory {
        case .enough:
            EmptyView()
        case .low(let gigabytes):
            if !model.memoryNoteSeen {
                note("Bekitzur is made for Macs with 32 GB of memory or more. With this Mac's \(gigabytes) GB, writing the Notes can be very slow, and may fail for a long Conversation.") {
                    Button("OK") { model.memoryNoteSeen = true }.controlSize(.small).hoverLight()
                }
            }
        case .tooLow(let gigabytes):
            note("Bekitzur needs 32 GB of memory to transcribe and write Notes, and this Mac has \(gigabytes) GB, so it doesn't download its models.") {
                EmptyView()
            }
        }
    }

    private func note(_ text: LocalizedStringKey, @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "memorychip").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            button()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
