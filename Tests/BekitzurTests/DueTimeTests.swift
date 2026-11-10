import Foundation
import Testing
@testable import BekitzurDomain

/// An Action Item's time of day: kept from its due phrase when the Notes are written, shown with its day, and changed
/// in the editor.
struct DueTimeTests {
    @Test func aTimeIsSavedAsHoursAndMinutes() {
        #expect(DueTime(hour: 9, minute: 5).saved == "09:05")
        #expect(DueTime(saved: "16:30") == DueTime(hour: 16, minute: 30))
        #expect(DueTime(saved: "25:00") == nil)
        #expect(DueTime(saved: "4pm") == nil)
    }

    /// Notes written before times were kept show the time their due phrase says, as their calendar events did.
    @Test func anItemFromBeforeTakesItsPhrasesTime() throws {
        let saved = #"{"text": "Review", "duePhrase": "tomorrow at 4pm", "dueDate": "2026-11-11", "sourceTurns": [], "quote": ""}"#
        let item = try JSONDecoder().decode(ActionItem.self, from: Data(saved.utf8))

        #expect(item.dueTime == nil)
        #expect(item.dueTimeOfDay == DueTime(hour: 16, minute: 0))
    }

    @Test func anotherDayKeepsTheTime() {
        var item = ActionItem(text: "Review", duePhrase: "tomorrow at 4pm", dueDate: "2026-11-11")

        item.setDue(day: "2026-11-12")

        #expect(item.dueDate == "2026-11-12")
        #expect(item.dueTimeOfDay == DueTime(hour: 16, minute: 0))
        #expect(item.duePhrase == nil)
    }

    @Test func takingTheTimeOffKeepsTheDay() {
        var item = ActionItem(text: "Review", duePhrase: "tomorrow at 4pm", dueDate: "2026-11-11", dueTime: "16:00")

        item.setDue(time: nil)

        #expect(item.dueDate == "2026-11-11")
        #expect(item.dueTimeOfDay == nil)
    }

    @Test func theDueDateShowsItsTime() throws {
        let item = ActionItem(text: "Review", dueDate: "2026-11-12", dueTime: "16:00")
        let english = try #require(NotesMarkdown.dueText(item, locale: Locale(identifier: "en_US")))
        let hebrew = try #require(NotesMarkdown.dueText(item, locale: Locale(identifier: "he_IL")))

        #expect(english.contains("Nov 12") && english.contains("4:00"))
        #expect(hebrew.contains("12 בנוב׳") && hebrew.contains("16:00"))
        #expect(NotesMarkdown.dueText(ActionItem(text: "Review", dueDate: "2026-11-12"), locale: Locale(identifier: "en_US")) == "Thu, Nov 12")
    }
}
