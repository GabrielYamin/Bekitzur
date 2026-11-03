import Foundation
import Testing
@testable import BekitzurDomain

/// Finding Conversations in the list by the people in them and by what they say.
struct ConversationSearchTests {
    private func result(speakers: [(String, SpeakerNaming)], summary: String = "Planning the release.", lines: [String] = []) -> ProcessedConversation {
        ProcessedConversation(
            transcript: Transcript(language: .hebrew, segments: lines.enumerated().map { TranscriptSegment(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) }),
            speakers: speakers.map { ConversationSpeaker(label: $0.0, speechSeconds: 10, embedding: [], naming: $0.1) },
            turns: [],
            notes: Notes(title: "Release", summary: summary, decisions: [Decision(text: "Ship on Thursday")], actionItems: [ActionItem(text: "Tell support")], openQuestions: [])
        )
    }

    @Test func thePeopleAreTheNamedSpeakersButTheUser() {
        let entry = SearchEntry(result(speakers: [
            ("Speaker 1", .named("Dana", similarity: 0.9)),
            ("Speaker 2", .named("gabriel", similarity: 0.8)),
            ("Speaker 3", .suggested("Avi", similarity: 0.6)),
            ("Speaker 4", .unknown),
        ]), user: " Gabriel ")

        #expect(entry.people == ["Dana"])
    }

    @Test func everyonePickedHasToBeInIt() {
        let both = SearchEntry(people: ["Dana", "Avi"], lines: [])
        let dana = SearchEntry(people: ["Dana"], lines: [])

        #expect(ConversationFilter(people: ["Dana", "Avi"]).matches(title: "Sync", entry: both))
        #expect(!ConversationFilter(people: ["Dana", "Avi"]).matches(title: "Sync", entry: dana))
        #expect(ConversationFilter(people: ["Dana"]).matches(title: "Sync", entry: dana))
        #expect(!ConversationFilter(people: ["Dana"]).matches(title: "Sync", entry: nil))
        #expect(ConversationFilter().matches(title: "Sync", entry: nil))
        #expect(!ConversationFilter(query: "  ").isActive)
    }

    @Test func theSearchLooksInTheTitleNotesAndTranscript() {
        let entry = SearchEntry(result(speakers: [], lines: ["נעבור ל-Redis בשבוע הבא", "בסדר גמור"]), user: "Gabriel")

        #expect(ConversationFilter(query: "release").matches(title: "Release plan", entry: entry))
        #expect(ConversationFilter(query: "THURSDAY").matches(title: "Sync", entry: entry))
        #expect(ConversationFilter(query: "redis").matches(title: "Sync", entry: entry))
        #expect(ConversationFilter(query: "בסדר").matches(title: "Sync", entry: entry))
        #expect(!ConversationFilter(query: "Kafka").matches(title: "Sync", entry: entry))
        #expect(!ConversationFilter(people: ["Dana"], query: "redis").matches(title: "Sync", entry: entry))
    }

    @Test func aMatchInsideShowsTheLineAroundIt() {
        let long = "We went over the migration plan in detail and agreed that moving the cache to Redis comes first, before anything else in the quarter, since everything waits on it."
        let entry = SearchEntry(people: [], lines: ["Short summary.", long])

        let excerpt = ConversationFilter(query: "redis").excerpt(title: "Sync", entry: entry)

        #expect(excerpt?.match == "Redis")
        #expect(excerpt?.before.hasPrefix("…") == true)
        #expect(excerpt?.after.hasSuffix("…") == true)
        #expect(excerpt.map { $0.before + $0.match + $0.after }?.contains("moving the cache to Redis comes first") == true)
        #expect(ConversationFilter(query: "sync").excerpt(title: "Sync", entry: entry) == nil)
        #expect(ConversationFilter(query: "Short").excerpt(title: "Sync", entry: entry) == ConversationFilter.Excerpt(before: "", match: "Short", after: " summary."))
    }

    @Test func peopleComeByHowManyConversationsTheyreIn() {
        let entries = [SearchEntry(people: ["Dana", "Avi"], lines: []), SearchEntry(people: ["Avi"], lines: []), SearchEntry(people: ["Bar"], lines: [])]

        let people = ConversationFilter.people(in: entries)

        #expect(people.map(\.name) == ["Avi", "Bar", "Dana"])
        #expect(people.map(\.conversations) == [2, 1, 1])
    }
}
