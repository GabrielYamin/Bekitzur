import Foundation
import Testing
@testable import BekitzurDomain

struct ConversationListTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static let now = date("2026-11-16T15:00:00Z")

    @Test(arguments: [
        ("2026-11-16T10:30:00Z", "today"),
        ("2026-11-16T23:00:00Z", "today"),
        ("2026-11-15T23:59:00Z", "yesterday"),
        ("2026-11-15T00:01:00Z", "yesterday"),
        ("2026-11-13T09:00:00Z", "previous7Days"),
        ("2026-11-09T09:00:00Z", "previous7Days"),
        ("2026-11-08T09:00:00Z", "previous30Days"),
        ("2026-10-17T09:00:00Z", "previous30Days"),
        ("2026-10-16T09:00:00Z", "2026-10-01"),
        ("2025-12-31T09:00:00Z", "2025-12-01"),
    ])
    func aDayFallsInItsSection(started: String, expected: String) {
        let section = DaySection.of(Self.date(started), now: Self.now, calendar: Self.calendar)

        let name: String
        switch section {
        case .today: name = "today"
        case .yesterday: name = "yesterday"
        case .previous7Days: name = "previous7Days"
        case .previous30Days: name = "previous30Days"
        case .month(let first): name = String(ISO8601DateFormatter().string(from: first).prefix(10))
        }

        #expect(name == expected)
    }

    @Test func conversationsSortedNewestFirstStayInOrderWithinTheirSections() {
        let started = ["2026-11-16T11:20:00Z", "2026-11-16T10:30:00Z", "2026-11-15T15:10:00Z", "2026-11-12T10:00:00Z", "2026-11-11T14:30:00Z", "2026-09-30T09:00:00Z"]

        let groups = DaySection.group(started, date: Self.date, now: Self.now, calendar: Self.calendar)
        let sections: [DaySection] = [.today, .yesterday, .previous7Days, .month(Self.date("2026-09-01T00:00:00Z"))]

        #expect(groups.map(\.section) == sections)
        #expect(groups.map(\.items.count) == [2, 1, 2, 1])
        #expect(groups[0].items == ["2026-11-16T11:20:00Z", "2026-11-16T10:30:00Z"])
    }

    @Test(arguments: [("Dana", "D"), ("Dana Cohen", "DC"), ("dana  cohen levi", "DL"), ("דנה כהן", "דכ"), ("Speaker 2", ""), ("", "")])
    func initialsAreTheFirstAndLastWordsFirstLetters(name: String, expected: String) {
        let initials = PersonMark.initials(of: name)

        #expect(initials == expected)
    }

    /// The same name gets the same color every time, which `hashValue`, seeded anew at each launch, wouldn't promise.
    @Test func aNamesColorIsAlwaysTheSameAndNamesSpreadOverTheColors() {
        let names = ["Dana", "Ron", "Maya", "Avi", "Noa", "Tal", "Yael", "Omer"]

        let first = names.map { PersonMark.colorIndex(of: $0, count: 8) }
        let again = names.map { PersonMark.colorIndex(of: $0, count: 8) }

        #expect(first == again)
        #expect(first.allSatisfy { (0..<8).contains($0) })
        #expect(Set(first).count > 3)
        #expect(PersonMark.colorIndex(of: "", count: 8) < 8)
    }
}
