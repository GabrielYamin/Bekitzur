import Foundation

/// An Action Item as an event in the iCalendar format (RFC 5545), which every calendar app reads, so it goes to whichever
/// app opens calendar files: Apple's calendar API reaches only the accounts in Calendar. The event is on the due day, at
/// the Action Item's time of day or 9:00, for half an hour, and shows as free, since it's a reminder rather than a meeting.
public struct CalendarEvent: Equatable, Sendable {
    /// The same for the same Action Item of a Conversation, so a calendar app updates the event added before.
    public var id: String
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date

    /// Nil for an Action Item without a due day.
    public init?(_ item: ActionItem, conversationID: String, conversationTitle: String, conversationDate: Date, calendar: Calendar = .current) {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        guard let dueDate = item.dueDate.flatMap(day.date(from:)) else { return nil }
        let time = item.dueTimeOfDay ?? DueTime(hour: 9, minute: 0)
        guard let start = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: dueDate) else { return nil }
        let said = DateFormatter()
        said.calendar = calendar
        said.timeZone = calendar.timeZone
        said.dateStyle = .long
        var notes = ["From \u{201C}\(conversationTitle)\u{201D}, \(said.string(from: conversationDate)), in Bekitzur."]
        if let owner = item.owner { notes.append("Owner: \(owner)") }
        if !item.quote.isEmpty { notes.append("\u{201C}\(item.quote)\u{201D}") }
        self.id = "\(conversationID)-\(Self.hash(item.text))@bekitzur.app"
        self.title = item.text
        self.notes = notes.joined(separator: "\n")
        self.start = start
        self.end = start.addingTimeInterval(30 * 60)
    }

    /// The event as an .ics file.
    public func ics(stamp: Date = Date()) -> String {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Bekitzur//Bekitzur//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(id)",
            "DTSTAMP:\(utc.string(from: stamp))",
            "DTSTART:\(utc.string(from: start))",
            "DTEND:\(utc.string(from: end))",
            "SUMMARY:\(Self.escaped(title))",
            "DESCRIPTION:\(Self.escaped(notes))",
            "TRANSP:TRANSPARENT",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.map(Self.folded).joined(separator: "\r\n") + "\r\n"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The line in lines of at most 75 bytes, each after the first starting with a space, without splitting a
    /// character: Hebrew letters are two bytes each.
    static func folded(_ line: String) -> String {
        var result = "", bytes = 0
        for character in line {
            let size = String(character).utf8.count
            if bytes + size > 75 {
                result += "\r\n "
                bytes = 1
            }
            result.append(character)
            bytes += size
        }
        return result
    }

    /// FNV-1a, which stays the same from one launch to the next, unlike Swift's own hashing.
    private static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }
}

/// The time of day a due phrase says, if it says one: "15:30", "3pm", "at 3", "noon", "בשעה שלוש וחצי", "ב-16:00",
/// "בצהריים". An hour with no am or pm, morning or afternoon, is a working hour: 8 to 12 in the morning and 1 to 7 in the
/// afternoon. A day or a part of the day alone ("tomorrow morning", "הערב") isn't a time.
public struct DueTime: Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// As Action Items save it: "16:00".
    public var saved: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public init?(saved: String) {
        let parts = saved.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        self.init(hour: hour, minute: minute)
    }

    private static let hebrewHours = ["אחת": 1, "שתיים": 2, "שתים": 2, "שלוש": 3, "ארבע": 4, "חמש": 5, "שש": 6, "שבע": 7, "שמונה": 8, "תשע": 9, "עשר": 10]

    public init?(in phrase: String) {
        let text = phrase.lowercased()
        var hour: Int?, minute = 0, suffix: String?
        if let match = text.firstMatch(of: /(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?/) {
            hour = Int(match.1)
            minute = Int(match.2) ?? 0
            suffix = match.3.map(String.init)
        } else if let match = text.firstMatch(of: /(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)/) {
            hour = Int(match.1)
            suffix = String(match.2)
        } else if let match = text.firstMatch(of: /\b(?:at|by)\s+(\d{1,2})\b(?!\s*(?:st|nd|rd|th|[\/.]))/) {
            hour = Int(match.1)
        } else if let match = text.firstMatch(of: /בשעה\s*(\d{1,2})/) {
            hour = Int(match.1)
        } else if let match = text.firstMatch(of: /ב-?\s*(\d{1,2})\s+(?:בבוקר|בצהריים|אחרי הצהריים|אחה״צ|בערב|בלילה)/) {
            // Only with a part of the day after it: "ב-3" alone is as likely the 3rd of the month.
            hour = Int(match.1)
        } else {
            hour = Self.hebrewHour(in: text)
        }
        guard var hour else {
            let noon = text.contains("noon") || text.contains("midday") || (text.contains("בצהריים") && !text.contains("אחרי הצהריים"))
            guard noon else { return nil }
            self.init(hour: 12, minute: 0)
            return
        }
        if minute == 0 {
            if text.contains("וחצי") { minute = 30 } else if text.contains("ורבע") { minute = 15 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if let suffix {
            if suffix.hasPrefix("p"), hour < 12 { hour += 12 }
            if suffix.hasPrefix("a"), hour == 12 { hour = 0 }
        } else if hour < 12 {
            let afternoon = ["afternoon", "evening", "tonight", "אחרי הצהריים", "אחה״צ", "אחה\"צ", "בצהריים", "בערב"].contains { text.contains($0) }
            let morning = text.contains("morning") || text.contains("בבוקר")
            if afternoon || (!morning && (1...7).contains(hour)) { hour += 12 }
        }
        self.init(hour: hour, minute: minute)
    }

    /// An hour in words after "בשעה" or as "ב" and the word: "בשעה שלוש", "בשלוש", "באחת עשרה".
    private static func hebrewHour(in text: String) -> Int? {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (i, word) in words.enumerated() {
            let name = word.hasPrefix("ב") && word != "בשעה" ? String(word.dropFirst()) : (i > 0 && words[i - 1] == "בשעה" ? word : nil)
            guard let name, let hour = hebrewHours[name] else { continue }
            let teen = i + 1 < words.count && words[i + 1] == "עשרה" && hour <= 2
            return teen ? hour + 10 : hour
        }
        return nil
    }
}
