import Synchronization

/// Hands blocks of audio from an audio thread to a writing thread without locks or allocation, so the audio thread only
/// copies and returns: a slow disk or a busy Mac can't make it miss its deadline. One thread puts blocks in, one takes
/// them out. When the writing thread falls behind by the ring's whole length, new blocks are lost, and the timestamps of
/// the next ones say how much.
final class AudioRing: @unchecked Sendable {
    struct Block {
        var frames = 0
        /// The device's count of its first frame, NaN when the device gave none.
        var sampleTime = Double.nan
        /// When its first frame was captured, 0 when unknown.
        var hostTime: UInt64 = 0
        /// The first block after the device restarted, whose sample count starts over.
        var restarted = false
    }

    let channels: Int
    let interleaved: Bool
    /// Frames in each slot; a longer block takes several.
    let slotFrames: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let blocks: UnsafeMutablePointer<Block>
    private let ticksPerFrame: Double
    private let added = Atomic<Int>(0)
    private let taken = Atomic<Int>(0)
    private let lostFrames = Atomic<Int>(0)

    /// - Parameters:
    ///   - seconds: How far the writing thread can fall behind before audio is lost.
    ///   - ticksPerSecond: Host-time ticks in a second, to time the slots a long block is split into.
    init(channels: Int, interleaved: Bool, sampleRate: Double, seconds: Double, ticksPerSecond: Double, slotFrames: Int = 512) {
        self.channels = channels
        self.interleaved = interleaved
        self.slotFrames = slotFrames
        slotCount = max(2, Int((seconds * sampleRate / Double(slotFrames)).rounded(.up)))
        samples = .allocate(capacity: slotCount * slotFrames * channels)
        samples.initialize(repeating: 0, count: slotCount * slotFrames * channels)
        blocks = .allocate(capacity: slotCount)
        blocks.initialize(repeating: Block(), count: slotCount)
        ticksPerFrame = ticksPerSecond / sampleRate
    }

    deinit {
        samples.deallocate()
        blocks.deallocate()
    }

    /// Frames lost because the writing thread fell too far behind.
    var lost: Int { lostFrames.load(ordering: .relaxed) }

    /// Puts a block in, a slot at a time. `copy` fills a slot, laid out as the ring is, with `count` frames starting at
    /// `offset` in the block. Call from the audio thread only.
    func put(frames: Int, sampleTime: Double, hostTime: UInt64, restarted: Bool, copy: (UnsafeMutablePointer<Float>, _ offset: Int, _ count: Int) -> Void) {
        var offset = 0
        var index = added.load(ordering: .relaxed)
        while offset < frames {
            guard index - taken.load(ordering: .acquiring) < slotCount else {
                lostFrames.wrappingAdd(frames - offset, ordering: .relaxed)
                break
            }
            let count = min(slotFrames, frames - offset)
            let slot = index % slotCount
            copy(samples + slot * slotFrames * channels, offset, count)
            blocks[slot] = Block(
                frames: count,
                sampleTime: sampleTime + Double(offset),
                hostTime: hostTime == 0 ? 0 : hostTime + UInt64(Double(offset) * ticksPerFrame),
                restarted: restarted && offset == 0
            )
            index += 1
            added.store(index, ordering: .releasing)
            offset += count
        }
    }

    /// Takes out every block put in so far, in order. Call from the writing thread only.
    func take(_ body: (Block, UnsafeMutablePointer<Float>) -> Void) {
        let end = added.load(ordering: .acquiring)
        var index = taken.load(ordering: .relaxed)
        while index < end {
            let slot = index % slotCount
            body(blocks[slot], samples + slot * slotFrames * channels)
            index += 1
            taken.store(index, ordering: .releasing)
        }
    }
}
