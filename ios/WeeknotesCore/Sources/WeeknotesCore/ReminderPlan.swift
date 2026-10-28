import Foundation

/// Weekly reminders are local notifications, so they work without an account and offline.
/// iOS can't skip one occurrence of a repeating notification, so the app schedules the next
/// few weeks one by one, leaving out weeks you've already logged, and plans again whenever you
/// save a week or change the time.
public enum ReminderPlan {
    public struct Settings: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// 0 = Sunday ... 6 = Saturday, like `profiles.reminder_weekday`.
        public var weekday: Int
        public var hour: Int
        public var minute: Int

        public init(enabled: Bool = true, weekday: Int = AppConfig.defaultReminderWeekday, hour: Int = 18, minute: Int = 0) {
            self.enabled = enabled
            self.weekday = weekday
            self.hour = hour
            self.minute = minute
        }
    }

    /// The next `count` reminder times after `now`, skipping any whose week is already logged.
    public static func dates(
        _ settings: Settings,
        after now: Date,
        in timeZone: TimeZone,
        logged: Set<LocalDate>,
        count: Int = 8,
        mondayCutoffHour: Int = AppConfig.mondayCutoffHour
    ) -> [Date] {
        guard settings.enabled else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar weekdays are 1 = Sunday ... 7 = Saturday
        let match = DateComponents(hour: settings.hour, minute: settings.minute, weekday: settings.weekday + 1)
        var out: [Date] = []
        var cursor = now
        // Look a little further than `count` weeks, since logged weeks are skipped
        for _ in 0..<(count + 60) where out.count < count {
            guard let next = calendar.nextDate(after: cursor, matching: match, matchingPolicy: .nextTime) else { break }
            cursor = next
            let week = Week.start(for: next, in: timeZone, mondayCutoffHour: mondayCutoffHour)
            if !logged.contains(week) { out.append(next) }
        }
        return out
    }
}
