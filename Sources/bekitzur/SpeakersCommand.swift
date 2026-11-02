import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurPipeline
import BekitzurSpeakers
import Foundation

struct SpeakersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speakers", abstract: "Separate and name the Speakers in an audio file.")

    @Argument(help: "Audio files. Two are a call's microphone and system audio tracks, in that order, separated as the app does.")
    var audio: [String] = []

    @Option(help: "A Conversation's folder instead: its tracks are lined up and separated as the app does, and each word of its Transcript is printed with its time, side (user or other), and Speaker.")
    var conversation: String?

    @Flag(help: "With --conversation: silence the microphone through all of the other side's speech, as before November 2, to compare.")
    var silencingAll = false

    @Option(help: "Voiceprints file.")
    var voiceprints: String = BekitzurPaths.voiceprints.path

    @Flag(name: .customLong("turns"), help: "Also print every turn the separator found.")
    var printTurns = false

    @Option(help: "combined (a timeline model's turns with pyannote's embeddings, as the app does), pyannote, sortformer, or nemotron.")
    var engine = "combined"

    @Option(help: "With combined: the model that says who spoke when, nemotron (as the app does) or sortformer.")
    var timeline: SpeakerSeparation.Timeline = .nemotron

    @Option(help: "How many people spoke, if known (combined and pyannote).")
    var people: Int?

    func run() async throws {
        if let conversation { return try await attribute(URL(filePath: conversation)) }
        guard !audio.isEmpty else { throw ValidationError("Give audio files or --conversation.") }
        let started = Date()
        let urls = audio.map { URL(filePath: $0) }
        let loaded = try ConversationProcessor.loadMixed(urls)
        let samples = loaded.samples
        let turns: [SpeakerTurn]
        switch engine {
        case "combined":
            if urls.count == 2, let microphone = loaded.tracks[urls[0]], let system = loaded.tracks[urls[1]] {
                turns = try await SpeakerSeparation.turns(in: samples, microphone: microphone, system: system, people: people, timeline: timeline)
            } else {
                turns = try await SpeakerSeparation.turns(in: samples, people: people, timeline: timeline)
            }
        case "sortformer":
            let separator = SortformerSeparator()
            try await separator.prepare()
            turns = try separator.separate(samples)
        case "nemotron":
            let separator = NemotronSeparator()
            try await separator.prepare()
            turns = try separator.separate(samples)
        case "pyannote":
            let separator = SpeakerSeparator(people: people)
            try await separator.prepare()
            turns = try await separator.separate(samples)
        default:
            throw ValidationError("--engine must be combined, pyannote, sortformer, or nemotron")
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

    /// A Conversation's tracks lined up by its delays and separated as the app does, and its Transcript's words given to
    /// the Speakers found.
    private func attribute(_ folder: URL) async throws {
        let started = Date()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(ConversationInfo.self, from: Data(contentsOf: folder.appending(path: "info.json")))
        let result = try decoder.decode(ProcessedConversation.self, from: Data(contentsOf: folder.appending(path: "result.json")))
        var lined = CallTracks(
            microphone: try AudioLoader.loadMono16k(folder.appending(path: "mic.m4a")),
            system: try AudioLoader.loadMono16k(folder.appending(path: "system.m4a"))
        ).delayingMicrophone(by: info.microphoneDelay ?? 0)
        if let delays = info.systemAudioDelays, !delays.isEmpty { lined = lined.tracks.placingSystemAudio(by: delays) }
        let turns = try await SpeakerSeparation.turns(
            in: lined.mixed,
            microphone: lined.tracks.microphone,
            system: lined.tracks.system,
            people: info.people,
            keepingTalkingOver: !silencingAll
        )
        let found = Speakers.name(Speakers.speakers(from: turns), with: try VoiceprintStore(url: URL(filePath: voiceprints)).load())
        let sides = Dictionary(found.map { ($0.displayName, $0.voice.hasPrefix("microphone") ? "user " : "other") }, uniquingKeysWith: { first, _ in first })
        for segment in Speakers.attribute(result.transcript.segments, turns: turns, speakers: found) {
            for word in segment.words ?? [] {
                print(String(format: "%8.2f  %@  %@  %@", word.start, sides[segment.speaker ?? ""] ?? "?    ", segment.speaker ?? "?", word.text))
            }
        }
        log(String(format: "%d turns, %d Speakers in %.1f s", turns.count, found.count, Date().timeIntervalSince(started)))
    }
}

extension SpeakerSeparation.Timeline: ExpressibleByArgument {}
