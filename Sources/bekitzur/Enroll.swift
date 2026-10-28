import ArgumentParser
import BekitzurAudio
import BekitzurPipeline
import BekitzurSpeakers
import Foundation

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Learn a Participant's Voiceprint from a voice sample.")

    @Argument(help: "The Participant's name.")
    var name: String

    @Argument(help: "A voice sample of about 30 seconds with only this person speaking.")
    var audio: String

    @Option(help: "Voiceprints file.")
    var voiceprints: String = BekitzurPaths.voiceprints.path

    func run() async throws {
        let samples = try AudioLoader.loadMono16k(URL(filePath: audio))
        let separator = SpeakerSeparator()
        try await separator.prepare()
        let turns = try await separator.separate(samples)
        let voices = Set(turns.map(\.voice)).count
        guard let voiceprint = Speakers.voiceprint(named: name, from: turns) else {
            throw ValidationError("No speech found in \(audio)")
        }
        try VoiceprintStore(url: URL(filePath: voiceprints)).save(voiceprint)
        log("Saved \(name)'s Voiceprint from \(String(format: "%.0f", turns.map(\.duration).reduce(0, +))) s of speech to \(voiceprints)")
        if voices > 1 {
            log("Warning: the sample has \(voices) voices; used the one that speaks most.")
        }
    }
}
