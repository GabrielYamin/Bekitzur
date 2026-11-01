import AVFoundation
import Foundation
import Testing
@testable import BekitzurCapture

/// Collects what a writer's listener hears; the listener is called on the writing thread.
private final class Heard: @unchecked Sendable {
    private(set) var samples: [Float] = []

    func add(_ buffer: UnsafeBufferPointer<Float>) {
        samples += buffer
    }
}

struct RecordingTimingTests {
    private static let rate = 48_000.0

    @Test func theFirstBlockComesAfterSilenceFromTheRecordingsStart() {
        let origin = mach_absolute_time()
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: origin)

        let placed = timeline.place(frames: 512, sampleTime: 9_000, hostTime: origin + AVAudioTime.hostTime(forSeconds: 0.1), restarted: false)

        #expect(placed.silence == 4_800 && placed.skip == 0)
        #expect(timeline.leadingSilence == 0.1)
        #expect(timeline.gaps == 0)
    }

    @Test func blocksCountedWithoutABreakFollowEachOther() {
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: nil)

        let placed = (0..<5).map { timeline.place(frames: 512, sampleTime: Double(1_000 + $0 * 512), hostTime: 0, restarted: false) }

        #expect(placed.allSatisfy { $0 == (0, 0) })
        #expect(timeline.position == 5 * 512)
    }

    /// November 1: seven blocks went missing from the system audio while the Mac was busy, and each moved the rest of
    /// the track earlier.
    @Test func aBlockCountedPastAMissingOneLeavesSilenceInItsPlace() {
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: nil)
        _ = timeline.place(frames: 1_024, sampleTime: 0, hostTime: 0, restarted: false)

        let placed = timeline.place(frames: 1_024, sampleTime: 2_048, hostTime: 0, restarted: false)

        #expect(placed.silence == 1_024 && placed.skip == 0)
        #expect(timeline.position == 3 * 1_024)
        #expect(timeline.gaps == 1 && timeline.silenceFrames == 1_024)
    }

    @Test func countsAFewFramesOffAreTheSameBoundaryAndMoveNothing() {
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: nil)

        let placed = [0.0, 512.4, 1_023.6, 1_540].map { timeline.place(frames: 512, sampleTime: $0, hostTime: 0, restarted: false) }

        #expect(placed.allSatisfy { $0 == (0, 0) })
        #expect(timeline.gaps == 0)
    }

    @Test func aBlockOverlappingTheLastLosesItsStart() {
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: nil)
        _ = timeline.place(frames: 1_024, sampleTime: 0, hostTime: 0, restarted: false)

        let placed = timeline.place(frames: 1_024, sampleTime: 1_000, hostTime: 0, restarted: false)

        #expect(placed.silence == 0 && placed.skip == 24)
        #expect(timeline.position == 2_024)
    }

    @Test func aDeviceThatStartedOverIsPlacedByWhenItsBlockWasCaptured() {
        let origin = mach_absolute_time()
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: origin)
        _ = timeline.place(frames: 48_000, sampleTime: 70_000, hostTime: origin, restarted: false)

        // After a change of device, a second later than the last block ended, counting from zero.
        let placed = timeline.place(frames: 512, sampleTime: 0, hostTime: origin + AVAudioTime.hostTime(forSeconds: 2), restarted: true)

        #expect(placed.silence == 48_000 && placed.skip == 0)
        #expect(timeline.restarts == 1)
        // From there the device's count is followed again.
        #expect(timeline.place(frames: 512, sampleTime: 512, hostTime: 0, restarted: false) == (0, 0))
    }

    @Test func withoutCountsBlocksArePlacedByTheClockIgnoringItsJitter() {
        let origin = mach_absolute_time()
        let at = { (seconds: Double) in origin + AVAudioTime.hostTime(forSeconds: seconds) }
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: origin)
        _ = timeline.place(frames: 4_800, sampleTime: .nan, hostTime: at(0), restarted: false)

        let jittery = timeline.place(frames: 4_800, sampleTime: .nan, hostTime: at(0.105), restarted: false)
        let late = timeline.place(frames: 4_800, sampleTime: .nan, hostTime: at(0.25), restarted: false)

        #expect(jittery == (0, 0))
        #expect(late.silence == 2_400)
    }

    @Test func blocksTheWritingThreadFellTooFarBehindForAreFilledWithSilence() {
        let ring = AudioRing(channels: 1, interleaved: false, sampleRate: 512, seconds: 4, ticksPerSecond: 1e9)
        var timeline = TrackTimeline(sampleRate: Self.rate, origin: nil)
        var file: [Float] = []
        let put = { (block: Int) in
            ring.put(frames: 512, sampleTime: Double(block * 512), hostTime: 0, restarted: false) { slot, _, count in
                slot.update(repeating: Float(block + 1), count: count)
            }
        }
        let takeAll = {
            ring.take { block, slot in
                let placed = timeline.place(frames: block.frames, sampleTime: block.sampleTime, hostTime: block.hostTime, restarted: block.restarted)
                file += [Float](repeating: 0, count: placed.silence) + UnsafeBufferPointer(start: slot + placed.skip, count: block.frames - placed.skip)
            }
        }

        // Six blocks while the writing thread is stuck: the ring holds four.
        for block in 0..<6 { put(block) }
        takeAll()
        put(6)
        takeAll()

        #expect(ring.lost == 2 * 512)
        #expect(file.count == 7 * 512)
        #expect(file[0..<2_048] == ArraySlice((1...4).flatMap { [Float](repeating: Float($0), count: 512) }))
        #expect(file[2_048..<3_072].allSatisfy { $0 == 0 })
        #expect(file[3_072...].allSatisfy { $0 == 7 })
    }

    @Test func aLongBlockIsSplitIntoSlotsThatKeepCounting() {
        let ring = AudioRing(channels: 2, interleaved: true, sampleRate: Self.rate, seconds: 1, ticksPerSecond: Self.rate)
        var blocks: [AudioRing.Block] = []

        ring.put(frames: 1_200, sampleTime: 100, hostTime: 5_000, restarted: true) { slot, offset, count in
            for i in 0..<count {
                slot[2 * i] = Float(offset + i)
                slot[2 * i + 1] = -Float(offset + i)
            }
        }
        var frames: [Float] = []
        ring.take { block, slot in
            blocks.append(block)
            frames += (0..<block.frames).map { slot[2 * $0] }
        }

        #expect(blocks.map(\.frames) == [512, 512, 176])
        #expect(blocks.map(\.sampleTime) == [100, 612, 1_124])
        #expect(blocks.map(\.hostTime) == [5_000, 5_512, 6_024])
        #expect(blocks.map(\.restarted) == [true, false, false])
        #expect(frames == (0..<1_200).map(Float.init))
    }

    @Test func aBlockLostOnTheWayLeavesSilenceInTheFileAndTheRestStaysInTime() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bekitzur-test-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 1_024))
        block.frameLength = 1_024
        for i in 0..<1_024 { block.floatChannelData![0][i] = 0.5 }
        let heard = Heard()

        let writer = try AudioFileWriter(url: url, format: mono) { samples, _ in heard.add(samples) }
        writer.write(block, sampleTime: 0)
        writer.write(block, sampleTime: 1_024)
        // Two blocks that never arrived.
        writer.write(block, sampleTime: 4_096)
        let report = writer.close()

        #expect(heard.samples.count == 5 * 1_024)
        #expect(heard.samples[0..<2_048].allSatisfy { $0 == 0.5 })
        #expect(heard.samples[2_048..<4_096].allSatisfy { $0 == 0 })
        #expect(heard.samples[4_096...].allSatisfy { $0 == 0.5 })
        #expect(report.gaps == 1)
        #expect(report.gapSeconds == 2_048 / Self.rate)
    }
}
