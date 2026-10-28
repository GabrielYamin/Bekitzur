import BekitzurAudio
import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurPipeline

struct LanguageDetectionTests {
    static let canDetect = LiveTranscriberTests.canTranscribe
        && FileManager.default.fileExists(atPath: BekitzurPaths.speechModel(for: .english).path)

    @Test func aSureGuessDecidesAfterTenSecondsOfSpeech() {
        #expect(LanguageDetection.decision([.hebrew: 0.97, .english: 0.03], heard: 10, ended: false) == .hebrew)
    }

    @Test func anUnsureGuessWaitsForMoreSpeech() {
        #expect(LanguageDetection.decision([.hebrew: 0.85, .english: 0.15], heard: 10, ended: false) == nil)
    }

    @Test func thirtySecondsOfSpeechOrTheEndDecideTheLikelier() {
        #expect(LanguageDetection.decision([.hebrew: 0.4, .english: 0.6], heard: 30, ended: false) == .english)
        #expect(LanguageDetection.decision([.hebrew: 0.75, .english: 0.25], heard: 13, ended: true) == .hebrew)
    }

    @Test func theTranscriptTakesTheAnswersLanguageOrKeepsTheAssumedOne() async throws {
        let cases: [(answered: ConversationLanguage?, expected: ConversationLanguage)] = [(.english, .english), (nil, .hebrew)]
        for (answered, expected) in cases {
            let live = LiveTranscriber(language: .hebrew, chunks: AnsweringChunks(language: answered), tracks: 1) { _ in }
            let tone = (0..<(25 * 16_000)).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 16_000) }

            tone.withUnsafeBufferPointer { live.receive($0, sampleRate: 16_000, track: 0) }
            let transcript = try #require(await live.finish())

            #expect(transcript.language == expected)
            #expect(transcript.segments.count == 1)
        }
    }

    @Test(.enabled(if: canDetect))
    func whileDetectingAChunkWithSpeechWaitsAndOneWithoutDoesNot() async throws {
        let read = try AudioLoader.loadMono16k(LiveTranscriberTests.scriptedRead)

        let (silence, first, rest) = try await offTheCooperativePool {
            // FluidAudio's debug build asserts that speech padding is no longer than the shortest speech, which the
            // speech detector's isn't, so here speech is wherever the audio isn't digital silence.
            let session = try ChunkSession(language: nil) { samples in
                samples.contains { $0 != 0 } ? [0...(Double(samples.count) / 16_000)] : []
            }
            return (
                session.answer([Float](repeating: 0, count: 25 * 16_000), at: 0),
                session.answer(Array(read[0..<(6 * 16_000)]), at: 25),
                session.answer(Array(read[(6 * 16_000)..<(40 * 16_000)]), at: 31)
            )
        }

        #expect(silence.count == 1 && silence[0].segments?.isEmpty == true && silence[0].language == nil)
        #expect(first.isEmpty)
        #expect(rest.count == 2 && rest.allSatisfy { $0.language == .hebrew && $0.segments?.isEmpty == false })
    }

    @Test(.enabled(if: canDetect))
    func englishIsDetectedAndTranscribedByRegularWhisper() async throws {
        let speech = try Self.synthesized(
            "We agreed to ship the new dashboard on Thursday. Dana will write the release notes, and Omer will check the alerts before the weekend. Let's meet again next week to see how the first users like it, and decide what comes next."
        )
        let live = LiveTranscriber(language: .hebrew, chunks: InProcessChunkTranscriber(language: nil, detectsSpeech: false), tracks: 1) { _ in }

        speech.withUnsafeBufferPointer { live.receive($0, sampleRate: 16_000, track: 0) }
        let transcript = try #require(await live.finish())

        #expect(transcript.language == .english)
        #expect(transcript.text.lowercased().contains("dashboard"))
    }

    /// English read by macOS's speech synthesizer.
    static func synthesized(_ text: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "bekitzur-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        return try AudioLoader.loadMono16k(file)
    }

    /// The session blocks on the speech detector, as the helper's loop does, which mustn't happen on Swift's threads.
    private func offTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// Answers each chunk at once with one line, in the language it was given.
private final class AnsweringChunks: LiveChunkTranscriber, @unchecked Sendable {
    let language: ConversationLanguage?

    init(language: ConversationLanguage?) {
        self.language = language
    }

    func transcribe(_ samples: [Float], at offset: Double, done: @escaping @Sendable ([TranscriptSegment]?, ConversationLanguage?) -> Void) {
        done([TranscriptSegment(start: offset, end: offset + 1, text: "line")], language)
    }

    func finish(_ done: @escaping @Sendable () -> Void) {
        done()
    }

    func cancel() {}
}
