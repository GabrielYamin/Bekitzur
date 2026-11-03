import AppKit
import BekitzurCapture
import SwiftUI

/// Something Bekitzur needs macOS to allow.
enum Permission: CaseIterable {
    case microphone, systemAudio, notifications

    var name: String {
        switch self {
        case .microphone: "microphone"
        case .systemAudio: "system audio"
        case .notifications: "notifications"
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .systemAudio: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
        }
    }
}

struct MissingPermission: Identifiable, Equatable {
    let permission: Permission
    let access: Access

    var id: Permission { permission }

    var message: String {
        switch (permission, access) {
        case (.microphone, .notAsked): "Bekitzur hasn't been allowed to use the microphone yet."
        case (.microphone, _): "Bekitzur isn't allowed to use the microphone, so it can't record."
        case (.systemAudio, .notAsked): "Bekitzur hasn't been allowed to record computer audio yet, which calls need for the other side."
        case (.systemAudio, _): "Bekitzur isn't allowed to record computer audio, so calls are recorded without the other side."
        case (.notifications, .notAsked): "Bekitzur hasn't been allowed to show notifications yet, like when Notes are ready."
        case (.notifications, _): "Notifications are off, so you won't be told when Notes are ready."
        }
    }
}

/// What macOS hasn't allowed Bekitzur, each with the way to allow it; nothing when everything is allowed.
struct PermissionsNote: View {
    let model: AppModel

    var body: some View {
        if !model.missingPermissions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.missingPermissions) { missing in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(missing.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(missing.access == .notAsked ? "Allow…" : "Open Settings") { model.allow(missing) }
                            .controlSize(.small)
                            .hoverLight()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
