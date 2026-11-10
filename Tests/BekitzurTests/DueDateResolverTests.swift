import Foundation
import Testing
@testable import BekitzurNotes

struct DueDateResolverTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()

    /// Sunday, the first day of the Israeli work week.
    private static let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 11))!

    private static func day(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return DueDateResolver.resolve(text, from: sunday, calendar: calendar).map(formatter.string(from:)) ?? "none"
    }

    @Test(arguments: [
        ("today", "2026-10-18"),
        ("היום", "2026-10-18"),
        ("tomorrow morning", "2026-10-19"),
        ("עד מחר", "2026-10-19"),
        ("מחרתיים", "2026-10-20"),
        ("עד רביעי בערב", "2026-10-21"),
        ("by Sunday", "2026-10-25"),
        ("next Wednesday", "2026-10-28"),
        ("ביום חמישי הבא", "2026-10-29"),
        ("סוף השבוע", "2026-10-22"),
        ("by the end of the week", "2026-10-22"),
        ("next week", "2026-10-29"),
        ("סוף החודש", "2026-10-31"),
        ("25/10", "2026-10-25"),
        ("1.3", "2027-03-01"),
        ("October 30", "2026-10-30"),
        ("sometime soon", "none"),
    ])
    func resolvesSpokenPhrases(phrase: String, expected: String) {
        #expect(Self.day(phrase) == expected)
    }

    /// The time of day comes with the day, and a time alone is on the Conversation's day.
    @Test(arguments: [
        ("tomorrow at 4PM", "2026-10-19 16:00"),
        ("מחר בארבע אחרי הצהריים", "2026-10-19 16:00"),
        ("by Thursday at 10:30", "2026-10-22 10:30"),
        ("עד יום חמישי בעשר וחצי", "2026-10-22 10:30"),
        ("at 2", "2026-10-18 14:00"),
        ("בשתיים", "2026-10-18 14:00"),
        ("by Friday", "2026-10-23"),
        ("ביום שני", "2026-10-19"),
        ("after the release", "none"),
    ])
    func dayAndTimeOfDay(phrase: String, expected: String) {
        let due = DueDateResolver.due(phrase, from: Self.sunday, calendar: Self.calendar)
        #expect(due.map { [$0.date, $0.time].compactMap(\.self).joined(separator: " ") } ?? "none" == expected)
    }
}
