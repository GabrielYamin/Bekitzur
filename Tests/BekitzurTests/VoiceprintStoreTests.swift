import BekitzurDomain
import Foundation
import Testing
@testable import BekitzurSpeakers

struct VoiceprintStoreTests {
    @Test func renamingKeepsTheVoiceAndMergesWithSomeoneAlreadyUnderTheName() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "voiceprints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceprintStore(url: url)
        try store.save(Voiceprint(name: "Dana", embedding: [1, 0]))
        try store.save(Voiceprint(name: "Avi", embedding: [0, 1]))

        try store.rename("Dana", to: "Dana Levi")
        #expect(try store.load().map(\.name).sorted() == ["Avi", "Dana Levi"])
        #expect(try store.load().first { $0.name == "Dana Levi" }?.embedding == [1, 0])

        try store.rename("Avi", to: "Dana Levi")
        let merged = try store.load()
        #expect(merged.map(\.name) == ["Dana Levi"])
        #expect(merged.first?.embedding == Speakers.average([1, 0], [0, 1]))

        try store.rename("Nobody", to: "Someone")
        #expect(try store.load() == merged)
    }
}
