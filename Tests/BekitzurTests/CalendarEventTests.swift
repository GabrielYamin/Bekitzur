import Foundation
import Testing
@testable import BekitzurDomain

/// An Action Item with a due day added to the calendar.
struct CalendarEventTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()

    private static let conversationDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

    private func event(due: String?, phrase: String?, text: String = "Send the report", quote: String = "אשלח מחר") -> CalendarEvent? {
        CalendarEvent(
            ActionItem(text: text, owner: "Dana", duePhrase: phrase, dueDate: due, sourceTurns: ["T004"], quote: quote),
            conversationID: "2026-11-04-100000",
            conversationTitle: "Weekly sync",
            conversationDate: Self.conversationDate,
            calendar: Self.calendar
        )
    }

    @Test(arguments: [
        ("tomorrow at 3pm", "15:00"),
        ("by 10:30", "10:30"),
        ("at 3", "15:00"),
        ("at 9", "09:00"),
        ("Thursday at 8 in the evening", "20:00"),
        ("tomorrow at noon", "12:00"),
        ("9:15 am", "09:15"),
        ("12am", "00:00"),
        ("מחר בשעה 15:00", "15:00"),
        ("עד מחר בשעה שלוש", "15:00"),
        ("בשמונה בבוקר", "08:00"),
        ("ביום חמישי בשלוש וחצי", "15:30"),
        ("באחת עשרה", "11:00"),
        ("ב-16:30", "16:30"),
        ("מחר בצהריים", "12:00"),
        ("ב-2 בצהריים", "14:00"),
        ("ב-8 בבוקר", "08:00"),
        ("ב-3 לחודש", "none"),
        ("tomorrow morning", "none"),
        ("by Friday", "none"),
        ("by the 5th", "none"),
        ("עד יום חמישי", "none"),
        ("הערב", "none"),
        ("31/10", "none"),
        ("אחרי הצהריים", "none"),
    ])
    func timeOfDayInTheDuePhrase(phrase: String, expected: String) {
        let time = DueTime(in: phrase).map { String(format: "%02d:%02d", $0.hour, $0.minute) } ?? "none"
        #expect(time == expected)
    }

    @Test func onTheDueDayAtTheTimeSaidOrNine() throws {
        let said = try #require(event(due: "2026-11-05", phrase: "tomorrow at 3pm"))
        let unsaid = try #require(event(due: "2026-11-05", phrase: "מחר"))

        #expect(Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: said.start) == DateComponents(year: 2026, month: 11, day: 5, hour: 15, minute: 0))
        #expect(Self.calendar.component(.hour, from: unsaid.start) == 9)
        #expect(said.end.timeIntervalSince(said.start) == 30 * 60)
        #expect(event(due: nil, phrase: "after the release") == nil)
        #expect(said.id == event(due: "2026-11-06", phrase: nil)?.id)
        #expect(said.id != event(due: "2026-11-05", phrase: nil, text: "Review the report")?.id)
    }

    @Test func theCalendarFileHasTheEventInUTC() throws {
        let file = try #require(event(due: "2026-11-05", phrase: nil, text: "Fix the build, then tell; QA")).ics(stamp: Self.conversationDate)

        #expect(file.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"))
        #expect(file.contains("\r\nDTSTART:20261105T070000Z\r\n"))
        #expect(file.contains("\r\nDTEND:20261105T073000Z\r\n"))
        #expect(file.contains("\r\nSUMMARY:Fix the build\\, then tell\\; QA\r\n"))
        #expect(file.contains("\r\nTRANSP:TRANSPARENT\r\n"))
        #expect(file.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
    }

    @Test func longLinesAreFoldedWithoutSplittingALetter() throws {
        let quote = String(repeating: "אני אשלח את הדוח מחר בבוקר לכל הצוות, ", count: 4)
        let file = try #require(event(due: "2026-11-05", phrase: nil, quote: quote)).ics(stamp: Self.conversationDate)

        let lines = file.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        let unfolded = file.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains(CalendarEvent.escaped("\u{201C}\(quote)\u{201D}")))
        #expect(unfolded.contains("Owner: Dana"))
    }
}
