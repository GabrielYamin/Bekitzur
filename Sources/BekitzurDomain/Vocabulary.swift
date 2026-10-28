import Foundation

/// The user's additions to the built-in English terms: their team's own terms, and Hebrew-letter spellings they taught
/// Bekitzur by correcting the Transcript.
public struct Vocabulary: Codable, Sendable, Equatable {
    /// Terms the team uses, like product names, that the built-in list doesn't have.
    public var terms: [String]
    /// Each spelling (a Hebrew-letter word without a prefix like ה) and the term it is.
    public var spellings: [String: String]

    public init(terms: [String] = [], spellings: [String: String] = [:]) {
        self.terms = terms
        self.spellings = spellings
    }
}
