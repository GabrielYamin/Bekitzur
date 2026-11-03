import BekitzurDomain
import Foundation

/// The People list on disk: one JSON file of Voiceprints, readable only by the user.
public struct VoiceprintStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [Voiceprint] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Voiceprint].self, from: Data(contentsOf: url))
    }

    /// Adds the Voiceprint, replacing any existing one with the same name.
    public func save(_ voiceprint: Voiceprint) throws {
        try write(try load().filter { $0.name != voiceprint.name } + [voiceprint])
    }

    /// Strengthens a Participant's Voiceprint with another sample of their voice, or adds it if they're new.
    /// A Speaker heard only by Sortformer has no embedding, and adds nothing.
    public func add(_ embedding: [Float], to name: String) throws {
        guard !embedding.isEmpty else { return }
        let existing = try load().first { $0.name == name }
        try save(Voiceprint(name: name, embedding: existing.map { Speakers.average($0.embedding, embedding) } ?? embedding))
    }

    public func delete(named name: String) throws {
        try write(try load().filter { $0.name != name })
    }

    /// Gives a Voiceprint another name. One already under the new name is the same person: their voices are averaged,
    /// as another sample would be.
    public func rename(_ name: String, to newName: String) throws {
        let voiceprints = try load()
        guard name != newName, let renamed = voiceprints.first(where: { $0.name == name }) else { return }
        let embedding = voiceprints.first { $0.name == newName }.map { Speakers.average($0.embedding, renamed.embedding) } ?? renamed.embedding
        try write(voiceprints.filter { $0.name != name && $0.name != newName } + [Voiceprint(name: newName, embedding: embedding)])
    }

    private func write(_ voiceprints: [Voiceprint]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(voiceprints).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
