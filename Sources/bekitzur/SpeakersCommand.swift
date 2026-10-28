import ArgumentParser
import BekitzurAudio
import BekitzurPipeline
import BekitzurSpeakers
import Foundation

struct SpeakersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speakers", abstract: "Separate and name the Speakers in an audio file.")

    @Argument(help: "Audio files. Two are a call's microphone and system audio tracks, in that order, separated as the app does.")
    var audio: [String]

    @Option(help: "Voiceprints file.")
    var voiceprints: String = BekitzurPaths.voiceprints.path

    @Flag(name: .customLong("turns"), help: "Also print every turn the separator found.")
    var printTurns = false

    @Option(help: "combined (Sortformer's timeline with pyannote's embeddings, as the app does), pyannote, or sortformer.")
    var engine = "combined"

    @Option(help: "How many people spoke, if known (combined and pyannote).")
    var people: Int?

    func run() async throws {
        let started = Date()
        let urls = audio.map { URL(filePath: $0) }
        let loaded = try ConversationProcessor.loadMixed(urls)
        let samples = loaded.samples
        let turns: [SpeakerTurn]
        switch engine {
        case "combined":
            if urls.count == 2, let microphone = loaded.tracks[urls[0]], let system = loaded.tracks[urls[1]] {
                turns = try await SpeakerSeparation.turns(in: samples, microphone: microphone, system: system, people: people)
            } else {
                turns = try await SpeakerSeparation.turns(in: samples, people: people)
            }
        case "sortformer":
            let separator = SortformerSeparator()
            try await separator.prepare()
            turns = try separator.separate(samples)
        case "pyannote":
            let separator = SpeakerSeparator(people: people)
            try await separator.prepare()
            turns = try await separator.separate(samples)
        default:
            throw ValidationError("--engine must be combined, pyannote, or sortformer")
        }
        let found = Speakers.name(Speakers.speakers(from: turns), with: try VoiceprintStore(url: URL(filePath: voiceprints)).load())
        found.forEach { print(describe($0)) }
        if printTurns {
            let labels = Dictionary(uniqueKeysWithValues: found.map { ($0.voice, $0.displayName) })
            for turn in turns.sorted(by: { $0.start < $1.start }) {
                print(String(format: "%7.2f → %7.2f  %@", turn.start, turn.end, labels[turn.voice] ?? turn.voice))
            }
        }
        log(String(format: "%d turns, %d Speakers in %.1f s", turns.count, found.count, Date().timeIntervalSince(started)))
    }
}
