import AVFoundation
import Foundation

/// Whether macOS lets Bekitzur use something it asks the user about.
public enum Access: String, Sendable {
    case granted
    case denied
    case notAsked = "not asked yet"
    case unknown
}

extension MicrophoneRecorder {
    public static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }
}

extension SystemAudioRecorder {
    /// Whether the user allowed System Audio Recording. macOS has no public way to tell, and a tap without it records
    /// silence instead of failing, so this asks TCC, which keeps the user's answers, through its private interface.
    /// Checked against the microphone's public status, it answers 1 when denied and 2 before the user is asked.
    public static var access: Access {
        guard let preflight = TCC.preflight else { return .unknown }
        return switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: .granted
        case 1: .denied
        case 2: .notAsked
        default: .unknown
        }
    }

    /// Asks the user for System Audio Recording, which otherwise happens when the first recording starts.
    public static func requestAccess() async -> Bool {
        guard let request = TCC.request else { return false }
        return await withCheckedContinuation { continuation in
            request("kTCCServiceAudioCapture" as CFString, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var preflight: Preflight? { function("TCCAccessPreflight") }
    static var request: Request? { function("TCCAccessRequest") }

    private static func function<T>(_ name: String) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
