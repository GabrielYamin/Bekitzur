import ArgumentParser
import BekitzurAudio
import BekitzurDomain
import BekitzurPipeline
import BekitzurSpeakers
import BekitzurTranscription
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio file, optionally with Speakers.")

    @Argument(help: "Audio file (any format macOS can read).")
    var audio: String

    @Option(help: "Conversation language: he, en, or auto to detect it from the first speech (with --live).")
    var language = LanguageChoice(.hebrew)

    @Option(help: "Speech model file. Defaults to the model for the language.")
    var model: String?

    @Flag(help: "Separate Speakers and name them from Voiceprints.")
    var speakers = false

    @Option(help: "Voiceprints file.")
    var voiceprints: String = BekitzurPaths.voiceprints.path

    @Option(help: "How many people spoke, if known.")
    var people: Int?

    @Option(help: "Write the Transcript as JSON to this file.")
    var json: String?

    @Option(help: "Text the speech model reads before every 30-second window, like an example sentence in the wanted style.")
    var prompt: String?

    @Flag(help: "Transcribe in chunks of 20 to 30 seconds cut at pauses, as the app does while recording.")
    var live = false

    @Flag(help: "With --live: transcribe every chunk whole, without detecting where people speak.")
    var wholeChunks = false

    func validate() throws {
        guard language.language == nil else { return }
        if !live { throw ValidationError("--language auto works with --live") }
        if model != nil { throw ValidationError("--model needs a language") }
    }

    func run() async throws {
        let started = Date()
        let samples = try AudioLoader.loadMono16k(URL(filePath: audio))
        var transcript: Transcript
        if let known = language.language, !live {
            let transcriber = try Transcriber(modelURL: model.map { URL(filePath: $0) } ?? BekitzurPaths.speechModel(for: known))
            transcript = Transcript(language: known, segments: try transcriber.transcribe(samples, language: known, prompt: prompt))
        } else {
            let helper = HelperChunkTranscriber(
                executable: Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]),
                arguments: ["live-helper", language.argument] + (model.map { ["--model", $0] } ?? []) + (wholeChunks ? ["--whole-chunks"] : [])
            )
            let transcriber = LiveTranscriber(language: language.language ?? .hebrew, chunks: helper, tracks: 1) { _ in }
            samples.withUnsafeBufferPointer { buffer in
                for start in stride(from: 0, to: buffer.count, by: 4_096) {
                    transcriber.receive(UnsafeBufferPointer(rebasing: buffer[start..<min(start + 4_096, buffer.count)]), sampleRate: AudioLoader.sampleRate, track: 0)
                }
            }
            guard let finished = await transcriber.finish() else { throw ValidationError("Live transcription failed") }
            transcript = finished
        }
        log(String(format: "Transcribed in %.1f s, in %@", Date().timeIntervalSince(started), transcript.language.rawValue))

        if speakers {
            let separated = Date()
            let turns = try await SpeakerSeparation.turns(in: samples, people: people)
            let found = Speakers.name(Speakers.speakers(from: turns), with: try VoiceprintStore(url: URL(filePath: voiceprints)).load())
            transcript.segments = Speakers.attribute(transcript.segments, turns: turns, speakers: found)
            log(String(format: "Separated %d Speakers in %.1f s", found.count, Date().timeIntervalSince(separated)))
            found.forEach { log("  " + describe($0)) }
        }

        for segment in transcript.segments {
            let who = segment.speaker.map { "\($0): " } ?? ""
            print(String(format: "[%7.2f → %7.2f] ", segment.start, segment.end) + who + segment.text)
        }
        if let json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(transcript).write(to: URL(filePath: json))
        }
        log(String(format: "%.0f s of audio in %.1f s", Double(samples.count) / AudioLoader.sampleRate, Date().timeIntervalSince(started)))
    }
}

func describe(_ speaker: Speaker) -> String {
    let naming: String
    switch speaker.naming {
    case .named(let name, let similarity): naming = String(format: "named %@ (%.2f)", name, similarity)
    case .suggested(let name, let similarity): naming = String(format: "Is this %@? (%.2f)", name, similarity)
    case .unknown: naming = "unknown"
    }
    let scores = speaker.similarities.sorted { $0.value > $1.value }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
    return String(format: "%@: %.0f s of speech, %@", speaker.label, speaker.speechSeconds, naming) + (scores.isEmpty ? "" : " [\(scores)]")
}
