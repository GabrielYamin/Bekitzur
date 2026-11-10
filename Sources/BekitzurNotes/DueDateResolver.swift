import BekitzurDomain
import Foundation

/// Turns a spoken due phrase ("עד יום חמישי", "by next Monday", "מחר בבוקר") into a date, counted from the
/// Conversation's date. The Israeli work week runs Sunday to Thursday, so "end of the week" means Thursday.
public enum DueDateResolver {
    private static let englishWeekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
    private static let hebrewWeekdays = ["ראשון": 1, "שני": 2, "שלישי": 3, "רביעי": 4, "חמישי": 5, "שישי": 6, "שבת": 7]
    private static let englishMonths = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let hebrewMonths = ["ינואר": 1, "פברואר": 2, "מרץ": 3, "אפריל": 4, "מאי": 5, "יוני": 6, "יולי": 7, "אוגוסט": 8, "ספטמבר": 9, "אוקטובר": 10, "נובמבר": 11, "דצמבר": 12]
    private static let hebrewPrefixes = ["ביום", "עד", "יום", "וב", "ב", "ל", "ה", "ו"]

    /// The day and time of day a due phrase says, as Action Items save them: "2026-11-05" and "16:00". A time without a
    /// day, like "at 4pm", is on the Conversation's day.
    public static func due(_ phrase: String, from conversationDate: Date, calendar: Calendar = .current) -> (date: String, time: String?)? {
        let time = DueTime(in: phrase)
        guard let day = resolve(phrase, from: conversationDate, calendar: calendar) ?? (time == nil ? nil : calendar.startOfDay(for: conversationDate)) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: day), time?.saved)
    }

    public static func resolve(_ phrase: String, from conversationDate: Date, calendar: Calendar = .current) -> Date? {
        let text = phrase.lowercased()
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let today = calendar.startOfDay(for: conversationDate)
        let weekday = calendar.component(.weekday, from: today)
        func days(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }
        func strippedHebrew(_ word: String) -> String {
            for prefix in hebrewPrefixes where word.hasPrefix(prefix) && word.count > prefix.count + 1 {
                return String(word.dropFirst(prefix.count))
            }
            return word
        }
        let isNext = words.contains("next") || text.contains("הבא") || text.contains("הבאה")
        let startOfNextWeek = days(8 - weekday)

        if text.contains("מחרתיים") || text.contains("day after tomorrow") { return days(2) }
        if words.contains("tomorrow") || words.contains(where: { strippedHebrew($0) == "מחר" || $0 == "מחר" }) { return days(1) }
        if words.contains("today") || words.contains("tonight") || words.contains("היום") || words.contains("הערב") { return today }

        let targetWeekday = words.lazy.compactMap { englishWeekdays[$0] ?? hebrewWeekdays[$0] ?? hebrewWeekdays[strippedHebrew($0)] }.first
        if let target = targetWeekday {
            if isNext { return calendar.date(byAdding: .day, value: target - 1, to: startOfNextWeek) }
            let ahead = (target - weekday + 7) % 7
            return days(ahead == 0 ? 7 : ahead)
        }
        if text.contains("end of the month") || text.contains("end of month") || text.contains("סוף החודש") || text.contains("סוף חודש") {
            let range = calendar.range(of: .day, in: .month, for: today)!
            return calendar.date(bySetting: .day, value: range.count, of: today)
        }
        if text.contains("end of the week") || text.contains("end of week") || text.contains("סוף השבוע") || text.contains("סוף שבוע") {
            return days((5 - weekday + 7) % 7)
        }
        if (words.contains("week") || text.contains("שבוע")) && isNext {
            return calendar.date(byAdding: .day, value: 4, to: startOfNextWeek)
        }
        return explicitDate(text, words: words, today: today, calendar: calendar)
    }

    /// "31/10", "31.10" (day first, as written in Israel), "October 31", "31 באוקטובר", within the next year.
    private static func explicitDate(_ text: String, words: [String], today: Date, calendar: Calendar) -> Date? {
        var day: Int?, month: Int?
        if let match = text.firstMatch(of: /(\d{1,2})[.\/](\d{1,2})/) {
            day = Int(match.1)
            month = Int(match.2)
        } else if let i = words.firstIndex(where: { monthNumber($0) != nil }) {
            month = monthNumber(words[i])
            let neighbors = [i > 0 ? words[i - 1] : nil, i + 1 < words.count ? words[i + 1] : nil]
            day = neighbors.lazy.compactMap { $0.flatMap(Int.init) }.first
        }
        guard let d = day, let m = month, (1...31).contains(d), (1...12).contains(m) else { return nil }
        let year = calendar.component(.year, from: today)
        return [year, year + 1].lazy
            .compactMap { calendar.date(from: DateComponents(year: $0, month: m, day: d)) }
            .first { $0 >= today }
    }

    private static func monthNumber(_ word: String) -> Int? {
        if word.count >= 3, word.allSatisfy(\.isLetter), let m = englishMonths[String(word.prefix(3))] { return m }
        return hebrewMonths[word] ?? hebrewMonths[String(word.dropFirst())]
    }
}
