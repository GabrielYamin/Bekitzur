import SwiftUI

/// Settings a release added. Until the user opens Settings after it, the Settings buttons in the main window and the menu
/// bar show a dot, and these are marked New in Settings while it's open.
enum NewSetting: Hashable {
    case recordCallsAutomatically

    /// One more each time a release adds settings, with `added` listing them.
    static let revision = 1
    static let added: Set<NewSetting> = [.recordCallsAutomatically]
}

/// On a Settings button while Settings has something the user hasn't seen.
struct NewDot: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .accessibilityLabel("New in Settings")
    }
}

/// Beside a setting a release added.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
    }
}
