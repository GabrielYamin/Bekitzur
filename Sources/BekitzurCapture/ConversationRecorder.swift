import Foundation

/// Records a Conversation as two tracks: the microphone and the Mac's system audio, as ADTS files that become .m4a
/// files once the Conversation is processed (`RecordingFiles`).
public final class ConversationRecorder {
    public enum Track: Int, Sendable, CaseIterable {
        case microphone, systemAudio

        /// The track's file name without its extension: .aac while recording, .m4a once processed.
        public var name: String {
            switch self {
            case .microphone: "mic"
            case .systemAudio: "system"
            }
        }

        var recordingFile: String { "\(name).\(RecordingFiles.recordingExtension)" }
    }

    private let microphone = MicrophoneRecorder()
    private let systemAudio = SystemAudioRecorder()

    public init() {}

    public typealias TrackListener = @Sendable (Track, UnsafeBufferPointer<Float>, Double) -> Void

    /// Both tracks start at the same moment, each file with silence until its device's first sound, and each block goes
    /// where its device's timestamps put it (`TrackTimeline`). Files that each started at their own first sound would
    /// be out of step by however long the second device took to start, so the copy of a call that laptop speakers put
    /// in the microphone would play before the call itself: an echo.
    /// - Parameters:
    ///   - microphone: The UID of the microphone to record (`AudioInputDevice`); nil for the Mac's default.
    ///   - listener: Gets a mono copy of each track as it's written, on that track's writing thread.
    public func start(in directory: URL, microphone device: String? = nil, listener: TrackListener? = nil) throws {
        let origin = mach_absolute_time()
        try systemAudio.start(
            writingTo: directory.appending(path: Track.systemAudio.recordingFile), origin: origin, listener: Self.listener(listener, for: .systemAudio)
        )
        do {
            try microphone.start(
                writingTo: directory.appending(path: Track.microphone.recordingFile),
                origin: origin,
                listener: Self.listener(listener, for: .microphone),
                device: device
            )
        } catch {
            systemAudio.stop()
            throw error
        }
    }

    private static func listener(_ listener: TrackListener?, for track: Track) -> AudioListener? {
        guard let listener else { return nil }
        return { samples, sampleRate in listener(track, samples, sampleRate) }
    }

    /// Stops both tracks and finishes their files, with how each kept time.
    @discardableResult
    public func stop() -> [Track: TrackReport] {
        var reports: [Track: TrackReport] = [:]
        reports[.microphone] = microphone.stop()
        reports[.systemAudio] = systemAudio.stop()
        return reports
    }
}
