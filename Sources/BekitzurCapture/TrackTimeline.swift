import AVFoundation

/// Where each block of a track goes in its file. The first comes after silence from the recording's start to when it
/// was captured. After that, the device's count of its frames says where each block belongs, so audio lost on the way
/// leaves silence in its place instead of moving the rest of the track earlier: blocks lost while the Mac was busy put
/// the November 1 call's system audio 171 ms ahead of the microphone in five minutes, and its other side echoed.
struct TrackTimeline {
    let sampleRate: Double
    /// The host time the recording started, shared by its tracks.
    let origin: UInt64?
    /// Frames in the file so far.
    private(set) var position = 0
    /// Seconds of silence before the first block, once it's placed.
    private(set) var leadingSilence: Double?
    private(set) var gaps = 0
    private(set) var silenceFrames = 0
    private(set) var overlapFrames = 0
    private(set) var restarts = 0
    /// The device's count of the frame expected next.
    private var expected: Double?

    /// A count that jumps further than this, or a block without one, is placed by when it was captured instead.
    private var longestJump: Double { 10 * sampleRate }
    /// Counts this close are the same boundary between blocks, not lost audio: a count can be fractional, and moving a
    /// frame or two at every block would click. A lost block is hundreds of frames.
    private let countTolerance = 16
    /// Placed by when it was captured, a block moves only if it's this far off, so the clock's jitter doesn't.
    private var clockTolerance: Int { Int(0.02 * sampleRate) }

    init(sampleRate: Double, origin: UInt64?) {
        self.sampleRate = sampleRate
        self.origin = origin
    }

    /// Frames of silence to write before a block, and frames to leave out from its start when it overlaps what's
    /// written, as a device's clock can.
    /// - Parameters:
    ///   - sampleTime: The device's count of the block's first frame; NaN without one.
    ///   - hostTime: When its first frame was captured; 0 when unknown.
    ///   - restarted: The device started over, as after a change of device, and counts from somewhere new.
    mutating func place(frames: Int, sampleTime: Double, hostTime: UInt64, restarted: Bool) -> (silence: Int, skip: Int) {
        var difference = 0
        let first = leadingSilence == nil
        if first {
            difference = max(0, framesSinceOrigin(hostTime) ?? 0)
            leadingSilence = Double(difference) / sampleRate
        } else if !restarted, !sampleTime.isNaN, let expected, abs(sampleTime - expected) < longestJump {
            difference = Int((sampleTime - expected).rounded())
            if abs(difference) < countTolerance { difference = 0 }
        } else if let target = framesSinceOrigin(hostTime) {
            difference = target - position
            if !restarted, abs(difference) <= clockTolerance { difference = 0 }
        }
        if restarted { restarts += 1 }
        let silence = max(0, difference), skip = min(frames, max(0, -difference))
        if !first, silence > 0 {
            gaps += 1
            silenceFrames += silence
        }
        overlapFrames += skip
        position += silence + frames - skip
        expected = sampleTime.isNaN ? nil : sampleTime + Double(frames)
        return (silence, skip)
    }

    private func framesSinceOrigin(_ hostTime: UInt64) -> Int? {
        guard let origin, hostTime != 0 else { return nil }
        let seconds = hostTime >= origin ? AVAudioTime.seconds(forHostTime: hostTime - origin) : -AVAudioTime.seconds(forHostTime: origin - hostTime)
        return Int((seconds * sampleRate).rounded())
    }
}
