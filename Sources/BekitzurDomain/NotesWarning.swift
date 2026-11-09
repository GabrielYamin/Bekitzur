import Foundation

/// What a Conversation's Notes miss because of its audio. It's saved in English, as `ConversationInfo.warning`, and
/// shown in the app's language.
public enum NotesWarning: Equatable, Sendable {
    case callUnreadable, microphoneUnreadable, noComputerAudio, silentMicrophone
    case liveTranscriptOnly(minutes: Int)

    /// A saved warning; nil for one this version doesn't know.
    public init?(saved: String) {
        let fixed: [NotesWarning] = [.callUnreadable, .microphoneUnreadable, .noComputerAudio, .silentMicrophone]
        if let warning = fixed.first(where: { $0.saved == saved }) {
            self = warning
        } else if let minutes = saved.split(separator: " ").lazy.compactMap({ Int($0) }).first,
                  saved == NotesWarning.liveTranscriptOnly(minutes: minutes).saved {
            self = .liveTranscriptOnly(minutes: minutes)
        } else {
            return nil
        }
    }

    public var saved: String {
        switch self {
        case .callUnreadable: "The call's sound couldn't be read, so these Notes only have what your microphone heard."
        case .microphoneUnreadable: "Your microphone's recording couldn't be read, so these Notes only have the call's sound."
        case .noComputerAudio: "No computer audio was recorded, so these Notes only have what your microphone heard. If this was a call, allow Bekitzur in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .silentMicrophone: "Your microphone recorded only silence. Check the input device in System Settings → Sound."
        case .liveTranscriptOnly(let minutes): "The audio couldn't be read, so these Notes come from the live Transcript of the first \(minutes) minutes, without Speakers."
        }
    }

    public var shown: String {
        switch self {
        case .callUnreadable: String(localized: "The call's sound couldn't be read, so these Notes only have what your microphone heard.")
        case .microphoneUnreadable: String(localized: "Your microphone's recording couldn't be read, so these Notes only have the call's sound.")
        case .noComputerAudio: String(localized: "No computer audio was recorded, so these Notes only have what your microphone heard. If this was a call, allow Bekitzur in System Settings → Privacy & Security → Screen & System Audio Recording.")
        case .silentMicrophone: String(localized: "Your microphone recorded only silence. Check the input device in System Settings → Sound.")
        case .liveTranscriptOnly(let minutes): String(localized: "The audio couldn't be read, so these Notes come from the live Transcript of the first \(minutes) minutes, without Speakers.")
        }
    }
}
