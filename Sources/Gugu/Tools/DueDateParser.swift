import Foundation
import GuguKernel

/// Turns the fuzzy Chinese time words produced by LocalCommandParser
/// ("明天" / "今晚" / "周一"…) into a concrete fire time, using fixed,
/// predictable default hours so a reminder can actually ring on schedule.
///
/// Defaults (chosen for predictability, not cleverness):
///   今晚            → 当天 20:00
///   今天            → 当天 09:00(已过则次日 09:00)
///   明天            → 次日 09:00
///   后天            → +2 天 09:00
///   下周            → +7 天 09:00
///   周一…周日       → 本周该天 09:00,已过/即当天则顺延到下周该天 09:00
/// Unrecognized words return nil (caller falls back to an immediate reminder).
enum DueDateParser {
    static let eveningHour = 20
    static let morningHour = 9

    static func parse(_ due: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = due.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if text.contains("今晚") || text.contains("今天晚上") {
            return at(hour: eveningHour, dayOffset: 0, from: now, calendar: calendar)
        }
        if text.contains("后天") {
            return at(hour: morningHour, dayOffset: 2, from: now, calendar: calendar)
        }
        if text.contains("明天") {
            return at(hour: morningHour, dayOffset: 1, from: now, calendar: calendar)
        }
        if text.contains("下周") {
            return at(hour: morningHour, dayOffset: 7, from: now, calendar: calendar)
        }
        if let weekday = weekdayIndex(in: text) {
            return nextWeekday(weekday, hour: morningHour, from: now, calendar: calendar)
        }
        if text.contains("今天") {
            // 09:00 today, or tomorrow 09:00 if already past
            if let today = at(hour: morningHour, dayOffset: 0, from: now, calendar: calendar, allowPast: false) {
                return today
            }
            return at(hour: morningHour, dayOffset: 1, from: now, calendar: calendar)
        }
        return nil
    }

    /// Date at `hour:00` on `now + dayOffset` days. When allowPast is false and
    /// the result is not in the future, returns nil.
    private static func at(hour: Int, dayOffset: Int, from now: Date,
                           calendar: Calendar, allowPast: Bool = true) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = 0
        guard let date = calendar.date(from: comps) else { return nil }
        if !allowPast && date <= now { return nil }
        return date
    }

    /// Map 周一…周日 to Calendar weekday (1 = Sunday … 7 = Saturday).
    private static func weekdayIndex(in text: String) -> Int? {
        let map: [(String, Int)] = [
            ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5),
            ("周五", 6), ("周六", 7), ("周日", 1), ("周天", 1),
        ]
        for (word, weekday) in map where text.contains(word) {
            return weekday
        }
        return nil
    }

    /// Next occurrence of `weekday` at `hour:00`; if that is today, roll to next
    /// week so the reminder is always in the future.
    private static func nextWeekday(_ weekday: Int, hour: Int, from now: Date,
                                    calendar: Calendar) -> Date? {
        let todayWeekday = calendar.component(.weekday, from: now)
        var delta = (weekday - todayWeekday + 7) % 7
        if delta == 0 { delta = 7 }   // "周一" said on a Monday means next Monday
        return at(hour: hour, dayOffset: delta, from: now, calendar: calendar)
    }
}
