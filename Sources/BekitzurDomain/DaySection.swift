import Foundation

/// The part of the Conversation list a day falls in, newest first, the way Notes groups its notes.
public enum DaySection: Hashable, Sendable {
    case today, yesterday, previous7Days, previous30Days
    /// A month before those, by its first day.
    case month(Date)

    public static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> DaySection {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2..<8: return .previous7Days
        case 8..<31: return .previous30Days
        default: return .month(calendar.dateInterval(of: .month, for: date)?.start ?? date)
        }
    }

    /// Items already sorted newest first, in their sections, in the same order.
    public static func group<Item>(_ items: [Item], date: (Item) -> Date, now: Date, calendar: Calendar = .current) -> [DayGroup<Item>] {
        var groups: [DayGroup<Item>] = []
        for item in items {
            let section = of(date(item), now: now, calendar: calendar)
            if groups.last?.section == section {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(DayGroup(section: section, items: [item]))
            }
        }
        return groups
    }
}

public struct DayGroup<Item> {
    public let section: DaySection
    public var items: [Item]
}
