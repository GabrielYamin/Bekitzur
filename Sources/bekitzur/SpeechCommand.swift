import ArgumentParser
import BekitzurAudio
import BekitzurSpeakers
import Foundation

struct SpeechCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speech",
        abstract: "List where people speak in an audio file, with voice activity detection.",
        shouldDisplay: false
    )

    @Argument(help: "Audio file.")
    var audio: String

    @Option(help: "How sure the model must be that a moment is speech (0 to 1).")
    var threshold: Float = 0.5

    func run() async throws {
        let samples = try AudioLoader.loadMono16k(URL(filePath: audio))
        let started = Date()
        let detector = try await SpeechDetector()
        let speech = try await detector.speech(in: samples, threshold: threshold)
        for range in speech {
            print(String(format: "%7.2f → %7.2f  (%.1f s)", range.lowerBound, range.upperBound, range.upperBound - range.lowerBound))
        }
        let total = speech.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        log(String(format: "%d stretches, %.0f of %.0f s speech, in %.1f s", speech.count, total, Double(samples.count) / AudioLoader.sampleRate, Date().timeIntervalSince(started)))
    }
}
