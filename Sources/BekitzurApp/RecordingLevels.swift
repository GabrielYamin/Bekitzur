import BekitzurCapture
import BekitzurDomain
import os
import SwiftUI

/// The loudest each track got since it was last read, kept from the recording's threads for the screen to read a
/// dozen times a second.
final class LevelMeter: Sendable {
    private let loudest = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: ConversationRecorder.Track.allCases.count))

    func receive(_ samples: UnsafeBufferPointer<Float>, track: ConversationRecorder.Track) {
        let level = AudioLevel.of(samples)
        loudest.withLock { $0[track.rawValue] = max($0[track.rawValue], level) }
    }

    /// Each track's loudest level since the last time, starting over.
    func take() -> (microphone: Float, systemAudio: Float) {
        loudest.withLock { levels in
            let taken = (levels[ConversationRecorder.Track.microphone.rawValue], levels[ConversationRecorder.Track.systemAudio.rawValue])
            levels = levels.map { _ in 0 }
            return taken
        }
    }
}

/// The last few levels of the microphone and of what the Mac plays, oldest first.
struct RecordingLevels: Equatable {
    static let kept = 12
    private(set) var microphone = [Float](repeating: 0, count: kept)
    private(set) var systemAudio = [Float](repeating: 0, count: kept)

    mutating func add(microphone: Float, systemAudio: Float) {
        self.microphone = Array((self.microphone + [microphone]).suffix(Self.kept))
        self.systemAudio = Array((self.systemAudio + [systemAudio]).suffix(Self.kept))
    }
}

/// A track's last few levels as bars, after a symbol for what it records, so both can be seen to be heard.
struct LevelBars: View {
    let symbol: String
    let levels: [Float]
    var height: CGFloat = 16

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 1.5) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 2.5, height: max(3, CGFloat(level) * height))
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
    }
}
