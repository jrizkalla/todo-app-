import Foundation

/// Scheduling a to-do into a *week* rather than onto a day.
///
/// "This week" and "next week" are how people actually plan a lot of work: the
/// commitment is real but the day is not decided yet, and forcing a date makes
/// the user invent one and then spend the week dragging it forward. This is the
/// vocabulary for that, and `Todo.weekAnchor` is where it lands.
///
/// The type is deliberately *not* what gets stored. The stored value is the
/// week's start date; this enum is the reading of that date relative to a given
/// "now", computed on the way out. That is what makes the rollover free:
/// nothing about a to-do changes when Monday arrives, but the same anchor that
/// read as `.nextWeek` on Sunday reads as `.thisWeek` on Monday, because the
/// week it is being compared against moved and the anchor did not.
enum WeekSchedule: String, Codable, CaseIterable, Sendable, Hashable {
    case thisWeek
    case nextWeek

    var label: String {
        switch self {
        case .thisWeek: "This Week"
        case .nextWeek: "Next Week"
        }
    }

    var symbolName: String {
        switch self {
        case .thisWeek: "calendar"
        case .nextWeek: "calendar.badge.clock"
        }
    }

    /// How many weeks past the current one this sits.
    var weekOffset: Int {
        switch self {
        case .thisWeek: 0
        case .nextWeek: 1
        }
    }
}

/// Week arithmetic, in one place so every caller agrees on where a week starts.
///
/// A free-standing enum rather than a `Calendar` extension because the interval
/// can fail to resolve — `dateInterval(of:for:)` is optional — and each caller
/// deciding for itself what to do about that is exactly how the descriptor path
/// and the array path drift apart.
enum WeekMath {
    /// The calendar every unqualified week calculation uses.
    ///
    /// This is the app's week-start preference, and defaulting to it rather
    /// than to `Calendar.current` is load-bearing rather than tidy. Anchors are
    /// matched by *equality* in the list predicates, so a write and a read that
    /// disagree about which day a week starts on produce anchors one day apart
    /// and the row is invisible in both lists.
    ///
    /// `Calendar.current` is not a safe default here even when the preference
    /// is off: `AppSettings.calendar` always pins `firstWeekday` to 1 or 2,
    /// while `Calendar.current` takes whatever the device locale says. The two
    /// agree only by luck of locale, which is precisely the kind of agreement
    /// that holds on the developer's machine and fails on a user's.
    ///
    /// Callers doing week arithmetic against a *specific* calendar — the tests,
    /// and a view that already holds `settings.calendar` — still pass one
    /// explicitly. This is only what "unspecified" means.
    ///
    /// Read from the shared app-group defaults rather than from `AppSettings`,
    /// which the widget extension does not build. One bool is the whole
    /// dependency, and taking it this way keeps the widget agreeing with the
    /// app about which week a to-do is in — the alternative was the widget
    /// silently using a different week boundary than the lists it mirrors.
    /// It is also the same key `AppSettings.weekStartsOnMonday` writes, so the
    /// two cannot drift.
    static var appCalendar: Calendar {
        var calendar = Calendar.current
        let startsOnMonday = UserDefaults(suiteName: AppSchema.appGroupIdentifier)?
            .bool(forKey: "weekStartsOnMonday")
            ?? UserDefaults.standard.bool(forKey: "weekStartsOnMonday")
        calendar.firstWeekday = startsOnMonday ? 2 : 1
        return calendar
    }

    /// Midnight on the first day of the week containing `date`.
    ///
    /// The unit of `weekAnchor`. Falls back to the start of the day when the
    /// calendar cannot resolve a week interval, which keeps the anchor a
    /// comparable date rather than making every caller handle nil — the
    /// fallback is wrong only for calendars that have no weeks, and it still
    /// leaves the to-do somewhere findable rather than nowhere.
    static func startOfWeek(containing date: Date, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? appCalendar
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    /// The anchor a to-do gets when scheduled into `schedule` as of `now`.
    static func anchor(
        for schedule: WeekSchedule,
        now: Date = Date(),
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? appCalendar
        let current = startOfWeek(containing: now, calendar: calendar)
        guard schedule.weekOffset != 0 else { return current }
        return calendar.date(byAdding: .weekOfYear, value: schedule.weekOffset, to: current)
            ?? current.addingTimeInterval(Double(schedule.weekOffset) * 7 * 24 * 3600)
    }

    /// What an anchor *means* right now, or nil if it means neither.
    ///
    /// Nil covers both directions: a week that has already ended (which the
    /// rollover clears) and one further out than next week (which nothing
    /// currently creates, but which an import or a clock change could produce,
    /// and which must not silently read as "next week").
    static func schedule(
        forAnchor anchor: Date,
        now: Date = Date(),
        calendar: Calendar? = nil
    ) -> WeekSchedule? {
        let calendar = calendar ?? appCalendar
        let anchorStart = startOfWeek(containing: anchor, calendar: calendar)
        for schedule in WeekSchedule.allCases
        where calendar.isDate(
            anchorStart,
            equalTo: self.anchor(for: schedule, now: now, calendar: calendar),
            toGranularity: .day
        ) {
            return schedule
        }
        return nil
    }

    /// The last moment of the week starting at `anchor` — exclusive.
    static func endOfWeek(startingAt anchor: Date, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? appCalendar
        return calendar.date(byAdding: .weekOfYear, value: 1, to: anchor)
            ?? anchor.addingTimeInterval(7 * 24 * 3600)
    }
}
