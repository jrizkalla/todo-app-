import Foundation

/// How a recurring to-do decides when its next instance is due.
///
/// The three cases are the ones the spec names, and they differ along one axis:
/// what the next date is measured from.
///
/// * `.onSchedule` — the calendar decides. The next instance appears on its date
///   whether or not the last one was ever finished, which is what a weekly
///   meeting or a monthly bill is.
/// * `.afterCompletionOnSchedule` — the calendar decides, but only once the
///   previous instance is done. "The first of the month, but don't nag me about
///   next month until I've handled this one."
/// * `.afterCompletion` — completion alone decides, and the date is a *gap*
///   rather than a calendar position: water the plants three days after the last
///   time you actually watered them, not every third day regardless.
///
/// Stored as a raw `String` for the same reason `CompletionState` is: CloudKit
/// mirroring wants primitives, and a new case must not require a migration.
enum RecurrenceMode: String, Codable, CaseIterable, Sendable {
    case onSchedule
    case afterCompletionOnSchedule
    case afterCompletion

    var label: String {
        switch self {
        case .onSchedule: "On schedule"
        case .afterCompletionOnSchedule: "On schedule, after completion"
        case .afterCompletion: "After completion"
        }
    }

    /// The one-line explanation under each option in the picker.
    var explanation: String {
        switch self {
        case .onSchedule:
            "The next one appears on its date, whether or not this one is done."
        case .afterCompletionOnSchedule:
            "The next date is skipped until this one is completed."
        case .afterCompletion:
            "The next one is scheduled a set time after this one is completed."
        }
    }

    var symbolName: String {
        switch self {
        case .onSchedule: "calendar"
        case .afterCompletionOnSchedule: "calendar.badge.checkmark"
        case .afterCompletion: "checkmark.arrow.trianglehead.counterclockwise"
        }
    }

    /// Whether this mode positions instances on calendar dates.
    ///
    /// `.afterCompletion` measures a gap from the completion instead, so the
    /// editor hides the day-of-week and day-of-month controls for it.
    var usesCalendarAnchor: Bool { self != .afterCompletion }

    /// Whether the previous instance must be resolved before the next appears.
    var waitsForCompletion: Bool { self != .onSchedule }
}

/// The unit a recurrence interval is counted in.
enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly

    /// The `Calendar.Component` the interval is added in.
    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }

    /// Singular noun, for "every day" / "every 3 days".
    var unitName: String {
        switch self {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
    }

    var pluralUnitName: String { unitName + "s" }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}

/// Whether a recurrence is running, on hold, or finished.
///
/// Paused and cancelled are deliberately separate. Pausing is temporary and
/// keeps the schedule intact — the spec asks for the paused template to be
/// visible in Anytime, which is what makes it findable to resume. Cancelling
/// ends the series and stops it appearing anywhere active.
enum RecurrenceStatus: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case cancelled

    var label: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .cancelled: "Cancelled"
        }
    }

    /// Whether the series should still be producing instances.
    var generatesInstances: Bool { self == .active }
}

/// The complete recurrence schedule for a template to-do.
///
/// A value type assembled from the template's stored columns rather than a
/// stored composite: `@Model` flattens a struct into one mandatory column per
/// member, which is precisely the migration failure `SchemaVersions.swift`
/// documents. Keeping the columns primitive and optional on `Todo` and
/// projecting them through this struct gets the ergonomics without the
/// migration hazard.
struct RecurrenceRule: Equatable, Hashable, Sendable {
    var mode: RecurrenceMode = .onSchedule
    var frequency: RecurrenceFrequency = .weekly
    /// How many `frequency` units between instances. Always at least 1.
    var interval: Int = 1

    /// Which weekdays a weekly rule fires on, as `Calendar` weekday numbers
    /// (1 = Sunday). Empty means "whatever weekday the anchor date falls on",
    /// which is how a plain "every 2 weeks" behaves.
    var weekdays: Set<Int> = []

    /// Day of the month for a monthly rule, or nil to track the anchor's day.
    var dayOfMonth: Int?

    /// Time of day instances are scheduled at, as minutes since midnight.
    ///
    /// Nil means the instances carry a date but no time, matching
    /// `Todo.assignedHasTime == false`.
    var timeOfDayMinutes: Int?

    /// When the series stops producing instances, if ever.
    var endDate: Date?

    var status: RecurrenceStatus = .active

    /// Clamp anything a UI or an import could get wrong.
    ///
    /// Called on the way into the store rather than trusted from callers: an
    /// interval of zero makes `nextDate` loop forever, and a day-of-month of 0
    /// or 40 silently produces no date at all.
    func normalized() -> RecurrenceRule {
        var copy = self
        copy.interval = max(1, interval)
        copy.weekdays = weekdays.filter { (1...7).contains($0) }
        if let day = dayOfMonth { copy.dayOfMonth = min(max(day, 1), 31) }
        if let minutes = timeOfDayMinutes {
            copy.timeOfDayMinutes = min(max(minutes, 0), 24 * 60 - 1)
        }
        // Weekdays only mean anything to a weekly rule; carrying them on a
        // monthly one would make the summary text lie about what fires.
        if frequency != .weekly { copy.weekdays = [] }
        if frequency != .monthly { copy.dayOfMonth = nil }
        return copy
    }
}

// MARK: - Human-readable summary

extension RecurrenceRule {
    /// The sentence shown on the expanded row and in the details section —
    /// "every Monday", "every 2 weeks at 3 PM", "when the previous one is
    /// complete".
    ///
    /// One function rather than a string built at each call site, because the
    /// row, the detail section, and the picker's header all show it and they
    /// must not drift.
    var summary: String {
        let base: String
        switch mode {
        case .afterCompletion:
            base = completionGapPhrase
        case .onSchedule, .afterCompletionOnSchedule:
            base = schedulePhrase
        }

        var text = base
        if let time = timePhrase, mode != .afterCompletion {
            text += " at \(time)"
        }
        if mode == .afterCompletionOnSchedule {
            text += ", once the previous one is complete"
        }
        if status == .paused {
            text += " (paused)"
        } else if status == .cancelled {
            text += " (cancelled)"
        }
        return text
    }

    /// "every 3 days after completion" — the gap phrasing.
    private var completionGapPhrase: String {
        if interval == 1 && frequency == .daily {
            return "a day after the previous one is complete"
        }
        let unit = interval == 1 ? frequency.unitName : "\(interval) \(frequency.pluralUnitName)"
        return "\(unit) after the previous one is complete"
    }

    /// "every Monday", "every 2 weeks", "every month on the 15th".
    private var schedulePhrase: String {
        switch frequency {
        case .daily:
            return interval == 1 ? "every day" : "every \(interval) days"

        case .weekly:
            if !weekdays.isEmpty {
                let names = weekdayNames
                let every = interval == 1 ? "every" : "every \(interval) weeks on"
                return "\(every) \(names)"
            }
            return interval == 1 ? "every week" : "every \(interval) weeks"

        case .monthly:
            let every = interval == 1 ? "every month" : "every \(interval) months"
            guard let day = dayOfMonth else { return every }
            return "\(every) on the \(Self.ordinal(day))"

        case .yearly:
            return interval == 1 ? "every year" : "every \(interval) years"
        }
    }

    /// Weekday names in week order, joined the way English lists them.
    private var weekdayNames: String {
        let symbols = Calendar.current.weekdaySymbols
        let names = weekdays
            .sorted()
            .compactMap { index -> String? in
                guard (1...7).contains(index) else { return nil }
                return symbols[index - 1]
            }

        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    var timePhrase: String? {
        guard let timeOfDayMinutes else { return nil }
        var components = DateComponents()
        components.hour = timeOfDayMinutes / 60
        components.minute = timeOfDayMinutes % 60
        guard let date = Calendar.current.date(from: components) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "1st", "2nd", "23rd" — used for day-of-month phrasing.
    static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Computing the next date

extension RecurrenceRule {
    /// The next date this rule fires on, strictly after `after`.
    ///
    /// `after` is the anchor the step is measured from — the previous
    /// instance's date for a calendar rule, the completion date for a
    /// `.afterCompletion` one. Returns nil once the series has run past its end
    /// date, which is what stops generation.
    ///
    /// Weekly rules with explicit weekdays are the one case that does not
    /// simply add an interval: they walk forward day by day to the next
    /// selected weekday, and only apply the week interval when they wrap past
    /// the end of a week. Anything else would make "every Monday and Thursday"
    /// mean "every 7 days from whichever one you picked first".
    func nextDate(after anchor: Date, calendar: Calendar = .current) -> Date? {
        let stepped: Date?

        switch frequency {
        case .weekly where !weekdays.isEmpty:
            stepped = nextWeekdayDate(after: anchor, calendar: calendar)
        case .monthly where dayOfMonth != nil:
            stepped = nextMonthlyDate(after: anchor, calendar: calendar)
        default:
            stepped = calendar.date(
                byAdding: frequency.component,
                value: max(1, interval),
                to: anchor
            )
        }

        guard let stepped else { return nil }
        let placed = applyingTimeOfDay(to: stepped, calendar: calendar)

        // The end date bounds the series inclusively on the day: a rule ending
        // "August 30" should still fire on the 30th.
        if let endDate, placed > calendar.startOfDay(for: endDate).addingTimeInterval(24 * 3600) {
            return nil
        }
        return placed
    }

    /// Walk forward to the next selected weekday.
    ///
    /// Scans day by day rather than computing an offset because the selected
    /// set can be any shape, and because the interval only advances when the
    /// scan crosses into a new week. Bounded at 371 days — a year and a week —
    /// so a rule that somehow matches nothing terminates rather than spinning.
    private func nextWeekdayDate(after anchor: Date, calendar: Calendar) -> Date? {
        let selected = weekdays.filter { (1...7).contains($0) }
        guard !selected.isEmpty else { return nil }

        let anchorDay = calendar.startOfDay(for: anchor)
        guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDay)?.start
        else { return nil }

        for offset in 1...371 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: anchorDay)
            else { return nil }
            guard selected.contains(calendar.component(.weekday, from: candidate)) else { continue }

            // Skip weeks that the interval does not land on: "every 2 weeks on
            // Monday" must not fire on the intervening Monday.
            guard interval > 1 else { return candidate }
            guard let candidateWeek = calendar.dateInterval(of: .weekOfYear, for: candidate)?.start
            else { return candidate }
            let weeksApart = calendar.dateComponents(
                [.weekOfYear], from: anchorWeek, to: candidateWeek
            ).weekOfYear ?? 0
            if weeksApart % interval == 0 { return candidate }
        }
        return nil
    }

    /// The next occurrence of `dayOfMonth`, clamped into months that are short.
    ///
    /// A rule set to the 31st has to do *something* in February. Clamping to
    /// the last day of the month is what a person means by "the last of the
    /// month", and it is what Reminders and Calendar both do — skipping the
    /// month entirely would silently drop two or three instances a year.
    private func nextMonthlyDate(after anchor: Date, calendar: Calendar) -> Date? {
        guard let requestedDay = dayOfMonth else { return nil }
        let step = max(1, interval)

        // Try this month first: the anchor may sit before this month's target
        // day, in which case the next fire is days away rather than a month.
        var monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: anchor)
        )
        // Bounded so a rule that can never resolve terminates.
        for attempt in 0...(step * 12 + 12) {
            guard let start = monthStart else { return nil }
            guard let candidate = dayInMonth(start, day: requestedDay, calendar: calendar)
            else { return nil }

            if candidate > calendar.startOfDay(for: anchor) {
                // Honour the interval: count whole months from the anchor.
                let monthsApart = calendar.dateComponents(
                    [.month],
                    from: calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? anchor,
                    to: start
                ).month ?? 0
                if monthsApart % step == 0 || attempt == 0 && step == 1 {
                    return candidate
                }
            }
            monthStart = calendar.date(byAdding: .month, value: 1, to: start)
        }
        return nil
    }

    /// `day` within the month starting at `monthStart`, clamped to its length.
    private func dayInMonth(_ monthStart: Date, day: Int, calendar: Calendar) -> Date? {
        let length = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 28
        var components = calendar.dateComponents([.year, .month], from: monthStart)
        components.day = min(day, length)
        return calendar.date(from: components)
    }

    /// Put the rule's time of day onto a computed date.
    ///
    /// Without a time the instance is a whole-day item and lands on the start
    /// of the day, which is what `assignedHasTime == false` means everywhere
    /// else in the app.
    func applyingTimeOfDay(to date: Date, calendar: Calendar = .current) -> Date {
        guard let timeOfDayMinutes else { return calendar.startOfDay(for: date) }
        return calendar.date(
            bySettingHour: timeOfDayMinutes / 60,
            minute: timeOfDayMinutes % 60,
            second: 0,
            of: date
        ) ?? date
    }

    /// Whether instances carry a time.
    var hasTime: Bool { timeOfDayMinutes != nil }
}
