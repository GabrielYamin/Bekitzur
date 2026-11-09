/// The language Bekitzur shows itself in: the Mac's, or one chosen in Settings. macOS reads the choice from the app's
/// own `AppleLanguages` preference when the app launches, the one System Settings → General → Language & Region →
/// Applications sets too, so a change shows once the app restarts.
public enum AppLanguage: String, CaseIterable, Sendable {
    case mac, english, hebrew

    /// The preference macOS reads at launch.
    public static let preference = "AppleLanguages"
    /// The layout's direction, which macOS also reads at launch: the language alone switches the text but leaves the
    /// layout left to right.
    public static let directionPreference = "AppleTextDirection"

    /// The language codes macOS reads for this choice; nil to follow the Mac.
    public var codes: [String]? {
        switch self {
        case .mac: nil
        case .english: ["en"]
        case .hebrew: ["he"]
        }
    }

    /// Whether the layout goes right to left; nil to follow the Mac.
    public var rightToLeft: Bool? {
        switch self {
        case .mac: nil
        case .english: false
        case .hebrew: true
        }
    }

    /// Whether the app shows this choice only once it restarts, having launched in `language`, laid out right to left
    /// or not (nil when it followed the Mac): a language chosen in System Settings comes without its direction.
    public func needsRestart(launchedIn language: AppLanguage, rightToLeft: Bool?) -> Bool {
        self != language || self.rightToLeft != rightToLeft
    }

    /// The choice in the app's own preferences, where `AppleLanguages` overrides the Mac's languages. A language
    /// Bekitzur has no translation for follows the Mac.
    public static func chosen(in preferences: [String: Any]?) -> AppLanguage {
        guard let first = (preferences?[preference] as? [String])?.first else { return .mac }
        if first.hasPrefix("he") || first.hasPrefix("iw") { return .hebrew }
        if first.hasPrefix("en") { return .english }
        return .mac
    }
}
