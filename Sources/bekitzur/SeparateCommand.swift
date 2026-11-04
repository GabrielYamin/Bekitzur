import ArgumentParser
import AVFoundation
import BekitzurAudio
import BekitzurPipeline
import BekitzurSpeakers
import Foundation

struct SeparateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "separate",
        abstract: "Split audio where two people talk at once into one file per voice, with the voice separation model."
    )

    @Argument(help: "Audio file.")
    var audio: String

    @Option(help: "Where to start, in seconds.")
    var from: Double = 0

    @Option(help: "Where to stop, in seconds; the end of the file by default.")
    var to: Double?

    @Option(help: "Folder for voice-1.wav and voice-2.wav.")
    var out: String = "."

    func run() async throws {
        guard let model = BekitzurPaths.voiceSeparation else {
            throw ValidationError("The voice separation model isn't downloaded: run bekitzur models --download")
        }
        let samples = try AudioLoader.loadMono16k(URL(filePath: audio))
        let rate = AudioLoader.sampleRate
        let start = min(samples.count, Int(from * rate)), end = min(samples.count, to.map { Int($0 * rate) } ?? samples.count)
        guard start < end else { throw ValidationError("Nothing between --from and --to") }
        var started = Date()
        let separator = try await VoiceSeparator(package: model.package, compiled: model.compiled)
        log(String(format: "Model loaded in %.1f s", Date().timeIntervalSince(started)))
        started = Date()
        let voices = try separator.separate(Array(samples[start..<end]))
        log(String(format: "Separated %.1f s in %.1f s", Double(end - start) / rate, Date().timeIntervalSince(started)))
        let folder = URL(filePath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, voice) in voices.enumerated() {
            let url = folder.appending(path: "voice-\(index + 1).wav")
            try write(voice, rate: rate, to: url)
            print(url.path)
        }
    }

    private func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let peak = samples.map(abs).max() ?? 0
        let scale: Float = peak > 0.99 ? 0.99 / peak : 1
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample * scale }
        try file.write(from: buffer)
    }
}
