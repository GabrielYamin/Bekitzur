import BekitzurLibrary
import Foundation
import Testing
@testable import BekitzurDomain

struct LibraryTests {
    @Test func conversationsRoundTripAndStayPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConversationLibrary(root: root)

        var info = try library.create(language: .english, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(library.all().map(\.status) == [.recording])

        info.status = .unreviewed
        info.title = "Planning"
        try library.save(info)
        let result = ProcessedConversation(
            transcript: Transcript(language: .english, segments: [TranscriptSegment(start: 0, end: 1, text: "Hi", speaker: "Speaker 1")]),
            speakers: [ConversationSpeaker(label: "Speaker 1", speechSeconds: 1, embedding: [0.5, 0.5], naming: .unknown)],
            turns: [Turn(id: "T001", speaker: "Speaker 1", text: "Hi", start: 0, end: 1)],
            notes: Notes(title: "Planning", summary: "Short.", decisions: [], actionItems: [], openQuestions: [])
        )
        try library.save(result, for: info.id)

        #expect(library.all() == [info])
        #expect(library.result(for: info.id) == result)
        for file in ["info.json", "result.json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: library.folder(for: info.id).appending(path: file).path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }

        try library.delete(info.id)
        #expect(library.all().isEmpty)
    }

    @Test func flagsRoundTripAndPointAtWordsByTimeAndText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConversationLibrary(root: root)
        let info = try library.create(language: .hebrew)
        let wrong = TranscriptWord(start: 230.46, end: 230.9, text: "אקזקטו")
        let right = TranscriptWord(start: 231.2, end: 231.5, text: "וואנס")

        var flags = library.flags(for: info.id)
        flags.toggle(wrong)
        flags.correct(wrong, as: " exactly ")
        flags.toggleSpeaker(lineStartingAt: 229.6, speaker: "Speaker 1")
        flags.listenedUntil = 240
        try library.save(flags, for: info.id)

        let loaded = library.flags(for: info.id)
        #expect(loaded == flags)
        #expect(loaded.flag(for: TranscriptWord(start: 230.461, end: 0, text: "אקזקטו"))?.correction == "exactly")
        #expect(loaded.flag(for: right) == nil)
        #expect(loaded.isSpeakerFlagged(lineStartingAt: 229.6))

        flags.toggle(wrong)
        #expect(flags.words.isEmpty)
        flags.assign(right, to: "Omer", transcribedAs: "Speaker 1")
        #expect(flags.flag(for: right)?.saidBy == "Omer")
        flags.assign(right, to: "Speaker 1", transcribedAs: "Speaker 1")
        #expect(flags.flag(for: right) == nil)
        library.deleteFlags(for: info.id)
        #expect(library.flags(for: info.id) == TranscriptFlags())
    }

    @Test func theLiveTranscriptIsKeptApartFromTheAudioAndStaysPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConversationLibrary(root: root)
        let info = try library.create(language: .hebrew)
        let live = LiveTranscript(transcript: Transcript(language: .hebrew, segments: [TranscriptSegment(start: 0, end: 1, text: "שלום")]), complete: true)

        try library.save(live, for: info.id)

        #expect(library.liveTranscript(for: info.id) == live)
        #expect(library.audioTracks(for: info.id).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: library.folder(for: info.id).appending(path: "live.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        library.deleteLiveTranscript(for: info.id)
        #expect(library.liveTranscript(for: info.id) == nil)
    }

    @Test func conversationsStartedInTheSameSecondGetTheirOwnFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bekitzur-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConversationLibrary(root: root)
        let started = Date(timeIntervalSince1970: 1_792_000_000)

        let first = try library.create(language: .hebrew, startedAt: started)
        let second = try library.create(language: .english, startedAt: started)

        #expect(second.id == first.id + "-2")
        #expect(library.all().count == 2)
    }
}
