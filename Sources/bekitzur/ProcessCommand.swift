import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurPipeline
import BekitzurSpeakers
import BekitzurVocabulary
import Foundation

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Transcribe, separate and name Speakers, and write Notes for one Recording."
    )

    @Argument(help: "Audio files. Several are mixed into one; two are a call's microphone and system audio tracks, in that order, whose Speakers are separated per side.")
    var audio: [String]

    @Option(help: "Conversation date, YYYY-MM-DD.")
    var date: String

    @Option(help: "Conversation language: he or en.")
    var language: ConversationLanguage = .hebrew

    @Option(help: "Voiceprints file.")
    var voiceprints: String = BekitzurPaths.voiceprints.path

    @Option(help: "Directory for transcript.json and notes.json.")
    var out: String

    func run() async throws {
        guard let day = parseDay(date) else { throw ValidationError("--date must be YYYY-MM-DD") }
        let started = Date()
        let urls = audio.map { URL(filePath: $0) }
        let loaded = try ConversationProcessor.loadMixed(urls)
        var samples = loaded.samples
        var call = urls.count == 2 ? loaded.tracks[urls[0]].flatMap { microphone in loaded.tracks[urls[1]].map { CallTracks(microphone: microphone, system: $0) } } : nil
        if let tracks = call {
            let delays = tracks.measuredSystemAudioDelays
            if !delays.isEmpty {
                let lined = tracks.placingSystemAudio(by: delays)
                call = lined.tracks
                samples = lined.mixed
                log("System audio played later to line up: " + delays.map { String(format: "%.0f ms from %.0f s", $0.delay * 1000, $0.from) }.joined(separator: ", "))
            }
        }
        let result = try await ConversationProcessor.process(
            samples,
            date: day,
            language: language,
            voiceprints: try VoiceprintStore(url: URL(filePath: voiceprints)).load(),
            call: call,
            vocabulary: VocabularyStore(url: BekitzurPaths.vocabulary).load()
        ) { step in
            log(String(format: "%@ (%.1f s)", step.rawValue, Date().timeIntervalSince(started)))
        }

        let directory = URL(filePath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(result.transcript).write(to: directory.appending(path: "transcript.json"))
        result.speakers.forEach { log("  \($0.label): \($0.displayName), \(String(format: "%.0f", $0.speechSeconds)) s") }
        try output(result.notes, completion: nil, json: directory.appending(path: "notes.json").path)
        log(String(format: "%.0f s of audio processed in %.1f s", Double(samples.count) / AudioLoader.sampleRate, Date().timeIntervalSince(started)))
    }
}
