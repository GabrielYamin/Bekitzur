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

    /// Both tracks start at the same moment, each file with silence until its device's first sound. Each used to start at
    /// its own first sound, and the microphone, started second, ran 9 to 212 ms ahead of the system audio, so the copy of
    /// a call that laptop speakers put in the microphone played before the call itself: an echo.
    /// - Parameter listener: Gets a mono copy of each track as it's recorded, on that track's audio thread.
    public func start(in directory: URL, listener: TrackListener? = nil) throws {
        let origin = mach_absolute_time()
        try systemAudio.start(
            writingTo: directory.appending(path: Track.systemAudio.recordingFile), origin: origin, listener: Self.listener(listener, for: .systemAudio)
        )
        do {
            try microphone.start(
                writingTo: directory.appending(path: Track.microphone.recordingFile), origin: origin, listener: Self.listener(listener, for: .microphone)
            )
        } catch {
            systemAudio.stop()
            throw error
        }
    }

    /// Seconds of silence each track's file starts with: how long its device took to deliver the first sound. Read it
    /// after stopping.
    public var leadingSilence: [Track: Double] {
        var silence: [Track: Double] = [:]
        silence[.microphone] = microphone.leadingSilence
        silence[.systemAudio] = systemAudio.leadingSilence
        return silence
    }

    private static func listener(_ listener: TrackListener?, for track: Track) -> AudioListener? {
        guard let listener else { return nil }
        return { samples, sampleRate in listener(track, samples, sampleRate) }
    }

    public func stop() {
        microphone.stop()
        systemAudio.stop()
    }
}
