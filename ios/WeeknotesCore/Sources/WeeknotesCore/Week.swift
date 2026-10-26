import Foundation

/// A calendar date with no time or zone ("2026-10-26"), as Postgres `date` stores it.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ iso: String) {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init(_ date: Date, in timeZone: TimeZone) {
        let c = Week.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    /// Midnight of this date in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date {
        Week.calendar(timeZone).date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> LocalDate {
        let utc = TimeZone(identifier: "UTC")!
        let moved = Week.calendar(utc).date(byAdding: .day, value: days, to: date(in: utc))!
        return LocalDate(moved, in: utc)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let date = LocalDate(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(value)"))
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}

/// Week boundaries. A week runs Monday 00:00 to Sunday 23:59 in the author's time zone, and
/// posts made before Monday 12:00 still count toward the week that just ended. Postgres has
/// the same rule in `week_start_for()`; `WeekTests` and the SQL tests share vectors.
public enum Week {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    /// The Monday of the week that something done at `date` belongs to.
    public static func start(for date: Date, in timeZone: TimeZone, mondayCutoffHour: Int = AppConfig.mondayCutoffHour) -> LocalDate {
        let calendar = calendar(timeZone)
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        // Calendar weekday: 1 = Sunday ... 7 = Saturday
        var daysSinceMonday = (c.weekday! + 5) % 7
        if daysSinceMonday == 0 && c.hour! < mondayCutoffHour { daysSinceMonday = 7 }
        return LocalDate(date, in: timeZone).adding(days: -daysSinceMonday)
    }

    /// "Oct 20 – 26", or "Sep 29 – Oct 5" across months.
    public static func label(for weekStart: LocalDate, locale: Locale = .current) -> String {
        let utc = TimeZone(identifier: "UTC")!
        let start = weekStart.date(in: utc)
        let end = weekStart.adding(days: 6).date(in: utc)
        var interval = Date.IntervalFormatStyle(locale: locale, timeZone: utc)
        interval = interval.month(.abbreviated).day()
        // The formatter uses thin spaces around the dash; plain spaces render the same everywhere
        return (start..<end).formatted(interval)
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
