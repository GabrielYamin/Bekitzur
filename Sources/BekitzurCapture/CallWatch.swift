import Foundation

/// When to suggest recording a call, and stopping once it's over, from the apps using the microphone.
///
/// A ringing call doesn't use the microphone yet, and seeing the ring in the call app's window would take permissions
/// that need an admin, so a call starts when a call app takes the microphone, as the user answers or joins. Browsers
/// count too, for Google Meet, though they don't say which site took it.
public struct CallWatch: Sendable {
    public enum Suggestion: Equatable, Sendable {
        /// Record the call in this app.
        case record(String)
        /// Stop recording, since the call in this app is over.
        case stop(String)
    }

    /// How long an app keeps the microphone before it counts as a call, since apps open it for a moment to check it.
    public static let startDelay: TimeInterval = 3
    /// How long the microphone stays off before a call counts as over, since muting can close it.
    public static let endDelay: TimeInterval = 20

    /// The app of the call going on, from when it takes the microphone until it's been off for `endDelay`.
    public private(set) var call: String?
    private var started = Date.distantPast
    private var microphoneOn = false
    private var lastHeard = Date.distantPast
    private var recording = false
    private var heardWhileRecording = false
    private var suggestedRecording = false

    public init() {}

    /// Call apps, then browsers, by the start of their bundle IDs, which their helper processes share.
    static let apps: [(prefix: String, name: String)] = [
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.microsoft.teams", "Teams"),
        ("us.zoom", "Zoom"),
        ("com.apple.FaceTime", "FaceTime"),
        // FaceTime's calls and phone calls relayed from an iPhone.
        ("com.apple.avconferenced", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.webex.meetingmanager", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome"),
        ("org.chromium.Chromium", "Chromium"),
        ("com.microsoft.edgemac", "Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.apple.Safari", "Safari"),
        // Safari records in WebKit's GPU process, which other apps' web views share.
        ("com.apple.WebKit.GPU", "Safari"),
    ]

    /// The call app or browser among apps using the microphone, by bundle ID, preferring a call app to a browser.
    public static func app(among bundleIDs: [String]) -> String? {
        bundleIDs.compactMap { id in apps.firstIndex { id.hasPrefix($0.prefix) } }.min().map { apps[$0].name }
    }

    /// What to suggest now, given the bundle IDs of the apps using the microphone and whether Bekitzur is recording.
    /// Call it whenever either changes, and again at `nextCheck`.
    public mutating func update(using bundleIDs: [String], recording: Bool, now: Date) -> Suggestion? {
        self.recording = recording
        if let app = Self.app(among: bundleIDs) {
            if call == nil {
                call = app
                started = now
                suggestedRecording = false
                heardWhileRecording = false
            }
            microphoneOn = true
            lastHeard = now
            if recording { heardWhileRecording = true }
        } else if microphoneOn {
            microphoneOn = false
            lastHeard = now
        }
        guard let call else { return nil }
        if microphoneOn, !recording, !suggestedRecording, now.timeIntervalSince(started) >= Self.startDelay {
            suggestedRecording = true
            return .record(call)
        }
        if !microphoneOn, now.timeIntervalSince(lastHeard) >= Self.endDelay {
            self.call = nil
            return recording && heardWhileRecording ? .stop(call) : nil
        }
        return nil
    }

    /// When a suggestion falls due if nothing changes before then.
    public var nextCheck: Date? {
        guard call != nil else { return nil }
        if microphoneOn { return recording || suggestedRecording ? nil : started.addingTimeInterval(Self.startDelay) }
        return lastHeard.addingTimeInterval(Self.endDelay)
    }
}
