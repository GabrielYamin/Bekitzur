import AVFoundation
import BekitzurAudio
import BekitzurPipeline
import Foundation
import Testing
@testable import BekitzurCapture

/// Collects what a writer's listener hears; the listener is called on the writing thread.
private final class Heard: @unchecked Sendable {
    private(set) var samples: [Float] = []
    private(set) var rate = 0.0

    func add(_ buffer: UnsafeBufferPointer<Float>, _ rate: Double) {
        samples += buffer
        self.rate = rate
    }
}

struct AudioTests {
    private static let rate = 48_000.0

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "bekitzur-test-\(UUID().uuidString).\(ext)")
    }

    private func tone(_ amplitude: Float, frame: Int, rate: Double = rate) -> Float {
        amplitude * sin(2 * .pi * 440 * Float(frame) / Float(rate))
    }

    @Test func microphoneWithManyChannelsIsWrittenAsMono() throws {
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let threeChannels = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, interleaved: false, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: threeChannels, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<3 {
            for i in 0..<48_000 { buffer.floatChannelData![channel][i] = tone(0.3, frame: i) }
        }

        let writer = try AudioFileWriter(url: url, format: mono)
        writer.write(buffer)
        writer.write(buffer)
        writer.close()

        #expect(try AVAudioFile(forReading: url).fileFormat.channelCount == 1)
        let samples = try AudioLoader.loadMono16k(url)
        #expect(abs(samples.count - 32_000) < 1_600)
        #expect((0.25...0.35).contains(samples.map(abs).max() ?? 0))
    }

    @Test func systemAudioIsTakenFromTheTapStreamsAfterAHeadsetMicrophone() throws {
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let frames = 4_800
        // A headset microphone stream (loud, constant) followed by the tap's two channels (a quiet tone).
        let streams: [[Float]] = [
            [Float](repeating: 0.9, count: frames),
            (0..<frames).map { tone(0.2, frame: $0) },
            (0..<frames).map { tone(0.2, frame: $0) },
        ]
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        defer { free(list.unsafeMutablePointer) }
        let storage = streams.map { stream in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: stream, count: frames)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        for (i, pointer) in storage.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pointer)
        }

        let writer = try AudioFileWriter(url: url, format: stereo)
        for _ in 0..<10 { writer.write(UnsafePointer(list.unsafePointer)) }
        writer.close()

        let samples = try AudioLoader.loadMono16k(url)
        #expect((0.15...0.25).contains(samples.map(abs).max() ?? 0))
    }

    @Test func aRecordingTheAppNeverFinishedCanStillBeRead() throws {
        let url = temporaryURL("aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 48_000))
        second.frameLength = 48_000
        for i in 0..<48_000 { second.floatChannelData![0][i] = tone(0.3, frame: i) }
        let writer = try AudioFileWriter(url: url, format: mono)
        for _ in 0..<10 { writer.write(second) }
        writer.flush()

        // Not closed, as when the app dies mid-recording.
        let samples = try AudioLoader.loadMono16k(url)

        // Every frame starts with ADTS's 12-bit sync word, so a reader finds frames without the end of the file.
        let start = try Data(contentsOf: url).prefix(2)
        #expect(start.first == 0xFF && (start.last ?? 0) & 0xF0 == 0xF0)
        #expect(samples.count > 9 * 16_000)
        #expect((0.25...0.35).contains(samples.map(abs).max() ?? 0))
        writer.close()
    }

    @Test func aProcessedRecordingBecomesAnM4AWithTheSameAudio() throws {
        let url = temporaryURL("aac")
        let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
        defer { [url, m4a].forEach { try? FileManager.default.removeItem(at: $0) } }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 48_000))
        second.frameLength = 48_000
        for i in 0..<48_000 { second.floatChannelData![0][i] = tone(0.3, frame: i) }
        let writer = try AudioFileWriter(url: url, format: mono)
        for _ in 0..<3 { writer.write(second) }
        writer.close()
        let recorded = try AudioLoader.loadMono16k(url)

        let finished = try RecordingFiles.finish(url)

        #expect(finished == m4a)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let samples = try AudioLoader.loadMono16k(m4a)
        #expect(abs(samples.count - 48_000) < 800)
        #expect(abs(samples.count - recorded.count) < 800)
        #expect((0.25...0.35).contains(samples.map(abs).max() ?? 0))
    }

    @Test func aRecordingCutOffByACrashBecomesAnM4AToo() throws {
        let url = temporaryURL("aac")
        let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
        defer { [url, m4a].forEach { try? FileManager.default.removeItem(at: $0) } }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 48_000))
        second.frameLength = 48_000
        for i in 0..<48_000 { second.floatChannelData![0][i] = tone(0.3, frame: i) }
        let writer = try AudioFileWriter(url: url, format: mono)
        for _ in 0..<5 { writer.write(second) }
        writer.flush()

        let finished = try RecordingFiles.finish(url)

        #expect(try AudioLoader.loadMono16k(finished).count > 4 * 16_000)
        writer.close()
    }

    @Test func aListenerHearsEachBufferInMonoAfterItsWritten() throws {
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for i in 0..<4_800 {
            buffer.floatChannelData![0][i] = 0.2
            buffer.floatChannelData![1][i] = 0.4
        }
        let heard = Heard()

        let writer = try AudioFileWriter(url: url, format: stereo) { samples, rate in heard.add(samples, rate) }
        writer.write(buffer)
        writer.close()

        #expect(heard.samples.count == 4_800)
        #expect(heard.samples.allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(heard.rate == Self.rate)
    }

    /// A microphone started after the system audio would run ahead if its file began at its own first sound.
    @Test func aTrackWhoseFirstSoundComesLateStartsWithSilenceFromTheRecordingsStart() throws {
        let url = temporaryURL("aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.5 }
        let heard = Heard()
        let origin = mach_absolute_time()

        let writer = try AudioFileWriter(url: url, format: mono, origin: origin) { samples, rate in heard.add(samples, rate) }
        writer.write(buffer, at: origin + AVAudioTime.hostTime(forSeconds: 0.25))
        writer.write(buffer, at: origin + AVAudioTime.hostTime(forSeconds: 0.35))
        writer.close()

        #expect(writer.leadingSilence == 0.25)
        #expect(heard.samples.count == 12_000 + 2 * 4_800)
        #expect(heard.samples.prefix(12_000).allSatisfy { $0 == 0 })
        #expect(heard.samples.dropFirst(12_000).allSatisfy { $0 == 0.5 })
    }

    @Test func tracksAreMixedAndSilentOnesAreReported() throws {
        let speech = temporaryURL("wav"), silence = temporaryURL("wav")
        defer { [speech, silence].forEach { try? FileManager.default.removeItem(at: $0) } }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        for (url, seconds, amplitude) in [(speech, 1, Float(0.2)), (silence, 2, Float(0))] {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds)))
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = tone(amplitude, frame: i, rate: 16_000) }
            try file.write(from: buffer)
        }

        let mixed = try ConversationProcessor.loadMixed([speech, silence, temporaryURL("m4a")])

        #expect(mixed.samples.count == 32_000)
        #expect(mixed.silentTracks == [silence])
        #expect((0.15...0.25).contains(mixed.samples.prefix(16_000).map(abs).max() ?? 0))
    }

    /// A track left unreadable, as system audio recorded through a headset that changed mode, leaves the other one.
    @Test func anUnreadableTrackIsLeftOutAndReported() throws {
        let speech = temporaryURL("wav"), damaged = temporaryURL("aac")
        defer { [speech, damaged].forEach { try? FileManager.default.removeItem(at: $0) } }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: speech, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<16_000 { buffer.floatChannelData![0][i] = tone(0.2, frame: i, rate: 16_000) }
            try file.write(from: buffer)
        }
        try Data().write(to: damaged)

        let mixed = try ConversationProcessor.loadMixed([speech, damaged])

        #expect(mixed.samples.count == 16_000)
        #expect(mixed.unreadableTracks == [damaged])
        #expect(throws: (any Error).self) { try ConversationProcessor.loadMixed([damaged]) }
    }

    /// During a change of device, as a Bluetooth headset switching to its call mode, the microphone can report a rate its
    /// hardware has already left, and a tap installed in it raises an exception that ends the app.
    @Test func aMicrophoneIsTappedOnlyAtTheRateItsHardwareRuns() throws {
        let current = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let headset = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))

        #expect(MicrophoneRecorder.canTap(current, hardware: current))
        #expect(!MicrophoneRecorder.canTap(current, hardware: headset))
    }
}
