import Foundation

/// The stored voice signature of a Participant: an average speaker embedding.
public struct Voiceprint: Codable, Sendable, Equatable {
    public var name: String
    public var embedding: [Float]

    public init(name: String, embedding: [Float]) {
        self.name = name
        self.embedding = embedding
    }
}

/// How a Speaker in a Conversation relates to the known Participants.
public enum SpeakerNaming: Codable, Sendable, Equatable {
    /// Confident match: the Speaker is shown under the Participant's name.
    case named(String, similarity: Float)
    /// Possible match: Review asks "Is this <name>?".
    case suggested(String, similarity: Float)
    case unknown
}
