import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurPipeline
import BekitzurSpeakers
import BekitzurTranscription
import Foundation

struct LanguageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "language",
        abstract: "Detect whether a recording is in Hebrew or English from its first speech."
    )

    @Argument(help: "Audio files. Several (a call's microphone and system audio tracks) are mixed into one, as the app does.")
    var audio: [String]

    @Option(help: "Speech model that detects: english, hebrew, or a model file.")
    var model = "english"

    @Option(parsing: .upToNextOption, help: "Seconds of speech to detect from, each tried in turn.")
    var speech: [Double] = [10, 30]

    @Option(help: "Minutes from the start of the recording to look for speech in.")
    var minutes = 5.0

    func run() async throws {
        let started = Date()
        let tracks = try audio.map { try AudioLoader.loadMono16k(URL(filePath: $0), upTo: minutes * 60) }
        var mixed = [Float](repeating: 0, count: tracks.map(\.count).max() ?? 0)
        for track in tracks { for i in track.indices { mixed[i] += track[i] } }

        let stretches = try await SpeechDetector().speech(in: mixed)
        let path = switch model {
        case "english": BekitzurPaths.speechModel(for: .english)
        case "hebrew": BekitzurPaths.speechModel(for: .hebrew)
        default: URL(filePath: model)
        }
        let transcriber = try Transcriber(modelURL: path)
        let rate = AudioLoader.sampleRate
        let total = stretches.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        for seconds in speech {
            var sample: [Float] = []
            for stretch in stretches where sample.count < Int(seconds * rate) {
                let from = max(0, Int(stretch.lowerBound * rate)), to = min(mixed.count, Int(stretch.upperBound * rate))
                if from < to { sample += mixed[from..<to] }
            }
            sample = Array(sample.prefix(Int(seconds * rate)))
            let (probabilities, likeliest) = try transcriber.detectLanguage(sample)
            print(String(format: "%4.0f s of speech: Hebrew %.3f, English %.3f; whisper's likeliest of all: %@",
                         Double(sample.count) / rate, probabilities[.hebrew] ?? 0, probabilities[.english] ?? 0, likeliest))
        }
        log(String(format: "%.0f s of speech in the first %.0f minutes; %.1f s", total, minutes, Date().timeIntervalSince(started)))
    }
}
