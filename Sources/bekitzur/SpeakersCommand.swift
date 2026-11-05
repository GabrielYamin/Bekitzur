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

    @Flag(help: "With --conversation: keep the other side in the microphone and silence it while they talk, except where the user talks over them, to compare.")
    var silencing = false

    @Flag(help: "With --conversation: also separate each input on its own and print how alike each microphone voice is to each system audio voice.")
    var similarities = false

    @Flag(help: "With --conversation: for a call, transcribe each input on its own as the app does, instead of using the saved Transcript.")
    var transcribe = false

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
        var microphoneSpeech: [ClosedRange<Double>] = []
        if !silencing {
            let cleaned = lined.tracks.removingEcho()
            lined = (cleaned.tracks, cleaned.mixed)
            microphoneSpeech = cleaned.microphoneSpeech
        }
        let known = try VoiceprintStore(url: URL(filePath: voiceprints)).load()
        if similarities {
            let user = Speakers.speakers(from: try await SpeakerSeparation.turns(in: lined.tracks.microphone))
            let other = Speakers.speakers(from: try await SpeakerSeparation.turns(in: lined.tracks.system))
            func cosine(_ a: [Float], _ b: [Float]) -> Float {
                guard a.count == b.count, !a.isEmpty else { return 0 }
                let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
                let norms = (a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 }).squareRoot()
                return norms > 0 ? dot / norms : 0
            }
            for u in user {
                let row = other.map { String(format: "%@ %.2f", $0.label, cosine(u.centroid, $0.centroid)) }.joined(separator: ", ")
                let name = Speakers.name([u], with: known).first.map(describe) ?? u.label
                log(String(format: "microphone %@ (%.0f s): system %@ | %@", u.label, u.speechSeconds, row, name))
            }
            for o in other { log("system " + (Speakers.name([o], with: known).first.map(describe) ?? o.label)) }
        }
        let turns = try await SpeakerSeparation.turns(
            in: lined.mixed,
            microphone: lined.tracks.microphone,
            system: lined.tracks.system,
            people: info.people,
            silencingOtherSide: silencing
        )
        let found = Speakers.name(Speakers.speakers(from: turns), with: known)
        let sides = Dictionary(found.map { ($0.displayName, $0.voice.hasPrefix("microphone") ? "user " : "other") }, uniquingKeysWith: { first, _ in first })
        var segments = result.transcript.segments
        if transcribe, !silencing, try await SpeakerSeparation.isCall(system: lined.tracks.system) {
            let language = info.language ?? result.transcript.language
            let system = try await transcribedLikeTheApp(lined.tracks.system, language: language)
            let microphone = try await transcribedLikeTheApp(lined.tracks.microphone, language: language)
            segments = ConversationProcessor.merging(microphone: microphone, system: system, microphoneSpeech: microphoneSpeech).segments
        }
        for segment in Speakers.attribute(segments, turns: turns, speakers: found) {
            let input = segment.input.map { $0 == .microphone ? "mic" : "sys" } ?? "-  "
            for word in segment.words ?? [] {
                print(String(format: "%8.2f  %@  %@  %@  %@", word.start, input, sides[segment.speaker ?? ""] ?? "?    ", segment.speaker ?? "?", word.text))
            }
        }
        log(String(format: "%d turns, %d Speakers in %.1f s", turns.count, found.count, Date().timeIntervalSince(started)))
    }
}

extension SpeakerSeparation.Timeline: ExpressibleByArgument {}

/// Transcribed as the app does, in chunks through a helper process: whisper.cpp's word timing aborts on short speech in
/// a long silence, as in a microphone with the other side silenced, when it gets the whole track at once.
func transcribedLikeTheApp(_ samples: [Float], language: ConversationLanguage) async throws -> Transcript {
    let helper = HelperChunkTranscriber(executable: Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]), arguments: ["live-helper", language.rawValue])
    let transcriber = LiveTranscriber(language: language, chunks: helper, tracks: 1) { _ in }
    samples.withUnsafeBufferPointer { buffer in
        for start in stride(from: 0, to: buffer.count, by: 4_096) {
            transcriber.receive(UnsafeBufferPointer(rebasing: buffer[start..<min(start + 4_096, buffer.count)]), sampleRate: AudioLoader.sampleRate, track: 0)
        }
    }
    guard let transcript = await transcriber.finish() else { throw ValidationError("Transcription failed") }
    return transcript
}
