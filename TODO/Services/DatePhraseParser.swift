import Foundation

/// A date recognized inside a piece of text.
struct DatePhraseMatch: Equatable {
    let date: Date
    /// Whether the phrase named a time of day, as opposed to a bare day.
    let hasTime: Bool
    /// Set when the phrase named a *week* rather than a day — "this week",
    /// "next week".
    ///
    /// `date` is still populated for these, with the week's anchor, so every
    /// caller that predates week scheduling keeps working unchanged and lands
    /// on a sensible day. Callers that understand weeks check this first and
    /// schedule the week instead, which is the more faithful reading: someone
    /// typing "next week" is declining to pick a day.
    var weekSchedule: WeekSchedule? = nil
    /// The substring that produced the match.
    let matchedText: String
    let matchedRange: NSRange
}

/// Finds dates written the way people actually type them.
///
/// `NSDataDetector` handles the fluent cases well ("tomorrow", "next friday",
/// "August 10 at 3pm") and brings localization with it, so it stays the primary
/// engine. What it does not reliably do is the clipped forms a keyboard-driven
/// user reaches for — "mon", "weds", "thurs", "aug 10", "8/10" — and those are
/// exactly the phrases the quick-schedule field is built around. This adds
/// them, and keeps the detector for everything else.
///
/// Written as a standalone parser rather than as more methods on `TitleParser`
/// because two callers want it now: the title chips, and the typed field in the
/// scheduling panel, which has no notion of chips or of a to-do at all.
struct DatePhraseParser {
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    init(referenceDate: Date = Date(), calendar: Calendar = .current) {
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }()

    // MARK: Entry points

    /// Every date phrase in `text`, ordered by position, with overlaps removed.
    ///
    /// The order of the engines here is the priority order used to settle
    /// overlaps, and the specific ones deliberately come before the detector.
    /// `NSDataDetector` answers for most of these phrases too, but less well:
    /// it reads "next friday" as the coming Friday rather than the one after,
    /// gives "tonight" an hour of its own choosing, and rolls an impossible
    /// date like "February 30" forward into March instead of rejecting it.
    /// Where this file has a rule of its own, that rule wins; the detector
    /// covers everything else and brings localization with it.
    func matches(in text: String) -> [DatePhraseMatch] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let all = explicitDateMatches(in: text)
            + relativeDayMatches(in: text)
            + weekdayMatches(in: text)
            + detectorMatches(in: text)

        return resolveOverlaps(all)
    }

    /// Interpret `text` as a date on its own, for a field whose entire contents
    /// are meant to be one.
    ///
    /// Distinct from `matches(in:)` in what it accepts: a bare "10" is a
    /// day-of-month here, because someone typing into a date field means a
    /// date, whereas in a to-do title it is far more likely a quantity.
    func parseWhole(_ text: String) -> DatePhraseMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let bare = bareDayOfMonth(trimmed) { return bare }

        // Prefer a match that covers the whole field; fall back to the first
        // one, so a stray word does not throw the parse away entirely.
        let found = matches(in: trimmed)
        let whole = found.first { $0.matchedRange.length == (trimmed as NSString).length }
        return whole ?? found.first
    }

    // MARK: NSDataDetector

    private func detectorMatches(in text: String) -> [DatePhraseMatch] {
        guard let detector = Self.detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)

        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let date = match.date else { return nil }
            let matched = (text as NSString).substring(with: match.range)

            // The detector rolls an impossible date forward rather than
            // refusing it — "February 30" comes back as March 2nd, silently
            // scheduling a day the user did not type. A phrase that names a
            // month and a day it does not have is dropped instead.
            guard !Self.namesImpossibleDay(matched) else { return nil }

            // The detector resolves bare days relative to *now* and hands back
            // noon; a phrase with a real clock time reads as having one.
            let hasTime = Self.containsTimeOfDay(matched)
            let resolved = hasTime ? date : calendar.startOfDay(for: date)

            return DatePhraseMatch(
                date: resolved,
                hasTime: hasTime,
                matchedText: matched,
                matchedRange: match.range
            )
        }
    }

    /// Whether a phrase pairs a month name with a day that month cannot have.
    ///
    /// February is checked at 29 days, so "February 29" survives to be resolved
    /// against a real year rather than being rejected outright in leap years.
    private static func namesImpossibleDay(_ text: String) -> Bool {
        let months = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"\b(\#(months))\.?\s+(\d{1,2})\b|\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(\#(months))\b"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }

        let nsText = text as NSString
        let found = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        return found.contains { match in
            // Either the "August 10" groups or the "10 August" ones matched.
            let monthRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 4)
            let dayRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)

            guard monthRange.location != NSNotFound, dayRange.location != NSNotFound,
                  let month = monthNames[nsText.substring(with: monthRange).lowercased()],
                  let day = Int(nsText.substring(with: dayRange))
            else { return false }

            return day > daysInMonth(month)
        }
    }

    /// Longest possible length of a month, ignoring the year.
    private static func daysInMonth(_ month: Int) -> Int {
        switch month {
        case 2: 29
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Whether a phrase names a clock time, as opposed to only a day.
    static func containsTimeOfDay(_ text: String) -> Bool {
        let pattern = #"(\d{1,2}:\d{2})|(\b\d{1,2}\s*(am|pm)\b)|\bnoon\b|\bmidnight\b|\btonight\b|\bthis evening\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Weekday abbreviations

    /// Abbreviated and full weekday names mapped to `Calendar` weekday numbers
    /// (1 = Sunday), including the informal spellings people type.
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "su": 1,
        "monday": 2, "mon": 2, "mo": 2,
        "tuesday": 3, "tue": 3, "tues": 3, "tu": 3,
        "wednesday": 4, "wed": 4, "weds": 4, "we": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "th": 5,
        "friday": 6, "fri": 6, "fr": 6,
        "saturday": 7, "sat": 7, "sa": 7,
    ]

    /// `mon`, `next fri`, `this weds`, optionally followed by a time.
    ///
    /// A bare weekday means the *next* one — typing "mon" on a Monday means the
    /// Monday coming, not today, which is what every calendar app does. "This"
    /// is the exception: it stays within the current week where it can.
    private func weekdayMatches(in text: String) -> [DatePhraseMatch] {
        let names = Self.weekdayNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"\b(next\s+|this\s+|coming\s+)?(\#(names))\b\.?(\s+(?:at\s+)?\#(Self.timeClause))?"#

        return regexMatches(pattern, in: text).compactMap { match, nsText in
            let nameRange = match.range(at: 2)
            guard nameRange.location != NSNotFound,
                  let weekday = Self.weekdayNames[nsText.substring(with: nameRange).lowercased()]
            else { return nil }

            let qualifier = match.range(at: 1).location == NSNotFound
                ? ""
                : nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()

            guard let day = nextDate(weekday: weekday, qualifier: qualifier) else { return nil }
            return finish(day: day, timeRange: match.range(at: 3), match: match, nsText: nsText)
        }
    }

    /// The next occurrence of `weekday`, honoring a "next"/"this" qualifier.
    private func nextDate(weekday: Int, qualifier: String) -> Date? {
        let start = calendar.startOfDay(for: referenceDate)
        let current = calendar.component(.weekday, from: start)

        // Always land on a future day: a bare weekday naming today means the
        // one a week out, since scheduling something for "monday" on Monday
        // morning almost never means the day already underway.
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }

        // "next friday" is the Friday after the coming one. The plain reading
        // has already moved into the week ahead, so this is always another
        // seven days on top — "this friday" is the one that means the nearest.
        if qualifier == "next" { delta += 7 }

        return calendar.date(byAdding: .day, value: delta, to: start)
    }

    // MARK: Explicit calendar dates

    private static let monthNames: [String: Int] = [
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    /// A trailing clock time: `3pm`, `3:30 pm`, `15:30`, `noon`.
    private static let timeClause = #"(?:(\d{1,2})(?::(\d{2}))?\s*(am|pm)|(\d{1,2}):(\d{2})|noon|midnight)"#

    /// `August 10`, `aug 10`, `10 aug`, `Aug 10, 2027`, `8/10`, `2027-08-10`.
    private func explicitDateMatches(in text: String) -> [DatePhraseMatch] {
        monthDayMatches(in: text) + dayMonthMatches(in: text) + numericMatches(in: text)
    }

    /// `August 10`, `aug 10th`, `Aug 10 2027`, optionally with a time.
    private func monthDayMatches(in text: String) -> [DatePhraseMatch] {
        let months = Self.monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"\b(\#(months))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b(\s+(?:at\s+)?\#(Self.timeClause))?"#

        return regexMatches(pattern, in: text).compactMap { match, nsText in
            guard let month = Self.monthNames[nsText.substring(with: match.range(at: 1)).lowercased()],
                  let day = Int(nsText.substring(with: match.range(at: 2)))
            else { return nil }

            let year = match.range(at: 3).location == NSNotFound
                ? nil
                : Int(nsText.substring(with: match.range(at: 3)))

            guard let date = resolve(month: month, day: day, year: year) else { return nil }
            return finish(day: date, timeRange: match.range(at: 4), match: match, nsText: nsText)
        }
    }

    /// `10 August`, `10th aug` — the order much of the world writes.
    private func dayMonthMatches(in text: String) -> [DatePhraseMatch] {
        let months = Self.monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(\#(months))\.?(?:,?\s+(\d{4}))?\b(\s+(?:at\s+)?\#(Self.timeClause))?"#

        return regexMatches(pattern, in: text).compactMap { match, nsText in
            guard let day = Int(nsText.substring(with: match.range(at: 1))),
                  let month = Self.monthNames[nsText.substring(with: match.range(at: 2)).lowercased()]
            else { return nil }

            let year = match.range(at: 3).location == NSNotFound
                ? nil
                : Int(nsText.substring(with: match.range(at: 3)))

            guard let date = resolve(month: month, day: day, year: year) else { return nil }
            return finish(day: date, timeRange: match.range(at: 4), match: match, nsText: nsText)
        }
    }

    /// `8/10`, `8/10/2027`, and ISO `2027-08-10`.
    ///
    /// Slash order follows the user's locale, so `8/10` is August 10th in the
    /// US and the 8th of October in most of Europe — reading it any other way
    /// would silently schedule the wrong day for half the world.
    private func numericMatches(in text: String) -> [DatePhraseMatch] {
        var results: [DatePhraseMatch] = []

        let iso = #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b(\s+(?:at\s+)?\#(Self.timeClause))?"#
        results += regexMatches(iso, in: text).compactMap { match, nsText in
            guard let year = Int(nsText.substring(with: match.range(at: 1))),
                  let month = Int(nsText.substring(with: match.range(at: 2))),
                  let day = Int(nsText.substring(with: match.range(at: 3))),
                  let date = resolve(month: month, day: day, year: year)
            else { return nil }
            return finish(day: date, timeRange: match.range(at: 4), match: match, nsText: nsText)
        }

        let slash = #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b(\s+(?:at\s+)?\#(Self.timeClause))?"#
        results += regexMatches(slash, in: text).compactMap { match, nsText in
            guard let first = Int(nsText.substring(with: match.range(at: 1))),
                  let second = Int(nsText.substring(with: match.range(at: 2)))
            else { return nil }

            let (month, day) = Self.monthFirstLocale ? (first, second) : (second, first)

            var year: Int?
            if match.range(at: 3).location != NSNotFound,
               let typed = Int(nsText.substring(with: match.range(at: 3))) {
                // Two digits are this century, the way every date field reads them.
                year = typed < 100 ? 2000 + typed : typed
            }

            guard let date = resolve(month: month, day: day, year: year) else { return nil }
            return finish(day: date, timeRange: match.range(at: 4), match: match, nsText: nsText)
        }

        return results
    }

    /// Whether this locale writes the month before the day in numeric dates.
    private static var monthFirstLocale: Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "Md",
            options: 0,
            locale: .current
        ) ?? "M/d"

        guard let monthIndex = format.firstIndex(of: "M"),
              let dayIndex = format.firstIndex(of: "d")
        else { return true }
        return monthIndex < dayIndex
    }

    /// Build a date from parts, defaulting the year to whichever reading is
    /// still ahead.
    ///
    /// Without a year, "aug 10" typed in December means next August, not the
    /// one eight months gone — a date field is nearly always pointed forward.
    private func resolve(month: Int, day: Int, year: Int?) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.month = month
        components.day = day
        components.year = year ?? calendar.component(.year, from: referenceDate)

        guard let candidate = calendar.date(from: components) else { return nil }
        // Reject a day the month does not have, rather than letting the
        // calendar roll it forward into the next one.
        guard calendar.component(.day, from: candidate) == day else { return nil }

        if year == nil, candidate < calendar.startOfDay(for: referenceDate) {
            components.year = (components.year ?? 0) + 1
            return calendar.date(from: components)
        }
        return candidate
    }

    // MARK: Relative days

    /// `today`, `tomorrow`, `tonight`, `in 3 days`, `in 2 weeks`.
    ///
    /// The detector covers most of these, but not consistently once a time is
    /// attached, and `tonight` it does not resolve at all.
    private func relativeDayMatches(in text: String) -> [DatePhraseMatch] {
        var results: [DatePhraseMatch] = []
        let start = calendar.startOfDay(for: referenceDate)

        let named = #"\b(today|tonight|tomorrow|yesterday)\b(\s+(?:at\s+)?\#(Self.timeClause))?"#
        results += regexMatches(named, in: text).compactMap { match, nsText in
            let word = nsText.substring(with: match.range(at: 1)).lowercased()

            let offset: Int
            switch word {
            case "tomorrow": offset = 1
            case "yesterday": offset = -1
            default: offset = 0
            }
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }

            // "tonight" carries an implied hour of its own, unless the text
            // names a real one.
            if word == "tonight", match.range(at: 2).location == NSNotFound {
                guard let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
                else { return nil }
                return DatePhraseMatch(
                    date: evening,
                    hasTime: true,
                    matchedText: nsText.substring(with: match.range),
                    matchedRange: match.range
                )
            }

            return finish(day: day, timeRange: match.range(at: 2), match: match, nsText: nsText)
        }

        // "this week" / "next week", and the "week after next" people reach for
        // when they mean neither.
        //
        // Deliberately before `counted` below, which would otherwise never see
        // these — but more importantly deliberately *not* resolved to a day.
        // The anchor rides along in `date` so older callers still work, and
        // `weekSchedule` is what a week-aware caller acts on.
        //
        // "week after next" resolves to a real anchor that reads as neither
        // list, so the field can say what it understood and the user can see
        // that it is further out than Next Week rather than being silently
        // rounded into it.
        let weeks = #"\b(this|next|(?:the\s+)?week\s+after\s+next)\s*(?:week)?\b"#
        results += regexMatches(weeks, in: text).compactMap { match, nsText in
            let raw = nsText.substring(with: match.range(at: 1)).lowercased()
            let whole = nsText.substring(with: match.range).lowercased()

            // "this"/"next" only mean a week when the word is actually there —
            // "next friday" is the weekday scanner's, and matching it here
            // would have the overlap resolver choose between two readings of
            // the same words on length alone.
            let offset: Int
            if raw.hasSuffix("after next") {
                offset = 2
            } else if whole.contains("week") {
                offset = raw == "next" ? 1 : 0
            } else {
                return nil
            }

            let anchor = calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: WeekMath.startOfWeek(containing: start, calendar: calendar)
            )
            guard let anchor else { return nil }

            return DatePhraseMatch(
                date: anchor,
                hasTime: false,
                weekSchedule: WeekMath.schedule(
                    forAnchor: anchor, now: self.referenceDate, calendar: calendar
                ),
                matchedText: nsText.substring(with: match.range),
                matchedRange: match.range
            )
        }

        let counted = #"\bin\s+(\d{1,3})\s+(day|days|week|weeks|month|months)\b"#
        results += regexMatches(counted, in: text).compactMap { match, nsText in
            guard let amount = Int(nsText.substring(with: match.range(at: 1))) else { return nil }
            let unit = nsText.substring(with: match.range(at: 2)).lowercased()

            let component: Calendar.Component = unit.hasPrefix("week")
                ? .weekOfYear
                : (unit.hasPrefix("month") ? .month : .day)

            guard let day = calendar.date(byAdding: component, value: amount, to: start) else { return nil }
            return DatePhraseMatch(
                date: day,
                hasTime: false,
                matchedText: nsText.substring(with: match.range),
                matchedRange: match.range
            )
        }

        return results
    }

    /// A field holding just a number, read as a day of the current month.
    private func bareDayOfMonth(_ text: String) -> DatePhraseMatch? {
        guard let day = Int(text), (1...31).contains(day) else { return nil }

        // Built directly rather than through `resolve`, which rolls a past date
        // forward by a *year*. A bare day of the month wants the next month
        // instead, so the rollover is done here.
        var components = DateComponents()
        components.year = calendar.component(.year, from: referenceDate)
        components.month = calendar.component(.month, from: referenceDate)
        components.day = day

        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day
        else { return nil }

        let resolved: Date
        if date < calendar.startOfDay(for: referenceDate) {
            // Skip to the same day next month, rejecting a month that has no
            // such day (the 31st of a 30-day month).
            components.month = (components.month ?? 1) + 1
            guard let next = calendar.date(from: components),
                  calendar.component(.day, from: next) == day
            else { return nil }
            resolved = next
        } else {
            resolved = date
        }

        return DatePhraseMatch(
            date: resolved,
            hasTime: false,
            matchedText: text,
            matchedRange: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    // MARK: Shared plumbing

    /// Attach an optional time clause to a resolved day.
    private func finish(
        day: Date,
        timeRange: NSRange,
        match: NSTextCheckingResult,
        nsText: NSString
    ) -> DatePhraseMatch? {
        var date = calendar.startOfDay(for: day)
        var hasTime = false

        if timeRange.location != NSNotFound {
            let clause = nsText.substring(with: timeRange)
            if let timed = applyTime(clause, to: date) {
                date = timed
                hasTime = true
            }
        }

        return DatePhraseMatch(
            date: date,
            hasTime: hasTime,
            matchedText: nsText.substring(with: match.range),
            matchedRange: match.range
        )
    }

    /// Parse `at 3pm`, `3:30 pm`, `15:30`, `noon` onto a given day.
    private func applyTime(_ clause: String, to day: Date) -> Date? {
        let text = clause.lowercased()

        if text.contains("noon") {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
        if text.contains("midnight") {
            return calendar.date(bySettingHour: 0, minute: 0, second: 0, of: day)
        }

        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }

        let nsText = text as NSString
        guard var hour = Int(nsText.substring(with: match.range(at: 1))) else { return nil }
        let minute = match.range(at: 2).location == NSNotFound
            ? 0
            : Int(nsText.substring(with: match.range(at: 2))) ?? 0

        if match.range(at: 3).location != NSNotFound {
            let meridiem = nsText.substring(with: match.range(at: 3))
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private func regexMatches(
        _ pattern: String,
        in text: String
    ) -> [(NSTextCheckingResult, NSString)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }

        let nsText = text as NSString
        return regex
            .matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            .map { ($0, nsText) }
    }

    /// Keep one match per stretch of text.
    ///
    /// Both the detector and the weekday scanner see "next tuesday"; without
    /// this the user would be offered the same day twice, once from each.
    ///
    /// Candidates arrive in engine-priority order (see `matches(in:)`) and that
    /// order is preserved for equal-length matches, so a phrase this file has
    /// its own rule for beats the detector's reading of the same words. A
    /// longer match still wins over a shorter one regardless of engine, which
    /// is what stops "aug 10" being reported as the bare day "10".
    private func resolveOverlaps(_ matches: [DatePhraseMatch]) -> [DatePhraseMatch] {
        let ranked = matches.enumerated().sorted { left, right in
            let (leftIndex, leftMatch) = left
            let (rightIndex, rightMatch) = right

            if leftMatch.matchedRange.length != rightMatch.matchedRange.length {
                return leftMatch.matchedRange.length > rightMatch.matchedRange.length
            }
            // Stable on engine priority, since `sorted` is not itself stable.
            return leftIndex < rightIndex
        }

        var kept: [DatePhraseMatch] = []
        for (_, match) in ranked {
            let overlaps = kept.contains {
                NSIntersectionRange($0.matchedRange, match.matchedRange).length > 0
            }
            if !overlaps { kept.append(match) }
        }

        return kept.sorted { $0.matchedRange.location < $1.matchedRange.location }
    }
}
