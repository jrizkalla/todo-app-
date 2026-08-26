import Testing
import Foundation
@testable import TODO

/// The date arithmetic behind a recurring to-do, tested away from the store.
///
/// `RecurrenceRule` is a value type on purpose, and this is the payoff: the
/// rules about weekday sets, short months, and end dates are the part most
/// likely to be wrong, and none of them need a database to check.
struct RecurrenceRuleTests {

    /// A fixed calendar, so a test cannot pass or fail on where it is run.
    ///
    /// Gregorian with Sunday as the first weekday and UTC throughout — weekday
    /// numbers and month boundaries both move otherwise.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: Simple intervals

    @Test func aDailyRuleStepsOneDay() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        let next = rule.nextDate(after: date(2026, 8, 26), calendar: calendar)
        #expect(next == date(2026, 8, 27))
    }

    @Test func anIntervalGreaterThanOneStepsThatMany() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 3)
        let next = rule.nextDate(after: date(2026, 8, 26), calendar: calendar)
        #expect(next == date(2026, 8, 29))
    }

    @Test func aMonthlyRuleWithoutADayTracksTheAnchor() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .monthly, interval: 1)
        let next = rule.nextDate(after: date(2026, 8, 15), calendar: calendar)
        #expect(next == date(2026, 9, 15))
    }

    @Test func aYearlyRuleStepsAYear() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .yearly, interval: 1)
        let next = rule.nextDate(after: date(2026, 8, 26), calendar: calendar)
        #expect(next == date(2027, 8, 26))
    }

    // MARK: Weekly with explicit days

    /// "Every Monday and Thursday" must hit both, not step seven days from one.
    @Test func aWeeklyRuleVisitsEachSelectedWeekday() {
        // 2026-08-26 is a Wednesday. Monday = 2, Thursday = 5.
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .weekly, interval: 1, weekdays: [2, 5]
        )

        let thursday = rule.nextDate(after: date(2026, 8, 26), calendar: calendar)
        #expect(thursday == date(2026, 8, 27))

        let monday = rule.nextDate(after: thursday!, calendar: calendar)
        #expect(monday == date(2026, 8, 31))
    }

    /// A two-week interval must skip the intervening week's Monday rather than
    /// firing on it — the bug a plain "add 7 days" would produce.
    @Test func aFortnightlyRuleSkipsTheInterveningWeek() {
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .weekly, interval: 2, weekdays: [2]
        )
        // Monday 2026-08-31.
        let next = rule.nextDate(after: date(2026, 8, 31), calendar: calendar)
        #expect(next == date(2026, 9, 14))
    }

    // MARK: Short months

    /// The 31st has to do something in a 30-day month; the last day is what a
    /// person means, and silently skipping the month is what must not happen.
    @Test func aMonthlyRuleClampsIntoShortMonths() {
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .monthly, interval: 1, dayOfMonth: 31
        )
        // From the end of January, February has no 31st.
        let next = rule.nextDate(after: date(2026, 1, 31), calendar: calendar)
        #expect(next == date(2026, 2, 28))
    }

    @Test func aMonthlyRuleFiresLaterInTheSameMonthWhenItCan() {
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .monthly, interval: 1, dayOfMonth: 20
        )
        let next = rule.nextDate(after: date(2026, 8, 5), calendar: calendar)
        #expect(next == date(2026, 8, 20))
    }

    // MARK: Time of day

    @Test func aRuleWithATimePlacesInstancesAtIt() {
        let rule = RecurrenceRule(
            mode: .onSchedule,
            frequency: .daily,
            interval: 1,
            timeOfDayMinutes: 15 * 60 + 30
        )
        let next = rule.nextDate(after: date(2026, 8, 26), calendar: calendar)
        #expect(next == date(2026, 8, 27, 15, 30))
        #expect(rule.hasTime)
    }

    @Test func aRuleWithoutATimeLandsAtTheStartOfTheDay() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        let next = rule.nextDate(after: date(2026, 8, 26, 14, 0), calendar: calendar)
        #expect(next == date(2026, 8, 27))
        #expect(!rule.hasTime)
    }

    // MARK: End date

    /// Past the end date the series is finished, which is what stops the engine
    /// generating forever.
    @Test func aRuleStopsAfterItsEndDate() {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        rule.endDate = date(2026, 8, 27)

        #expect(rule.nextDate(after: date(2026, 8, 26), calendar: calendar) == date(2026, 8, 27))
        #expect(rule.nextDate(after: date(2026, 8, 28), calendar: calendar) == nil)
    }

    /// The bound is inclusive on the day: a rule ending on the 27th still fires
    /// on the 27th, whatever time of day the end date happens to carry.
    @Test func theEndDateIncludesItsOwnDay() {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        rule.endDate = date(2026, 8, 27, 9, 0)

        #expect(rule.nextDate(after: date(2026, 8, 26), calendar: calendar) == date(2026, 8, 27))
    }

    // MARK: Normalization

    /// An interval of zero would make the engine's walk non-terminating, so it
    /// is clamped rather than trusted.
    @Test func normalizationClampsTheInterval() {
        let rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 0)
        #expect(rule.normalized().interval == 1)
    }

    @Test func normalizationClampsTheDayOfMonth() {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .monthly, interval: 1)
        rule.dayOfMonth = 40
        #expect(rule.normalized().dayOfMonth == 31)

        rule.dayOfMonth = 0
        #expect(rule.normalized().dayOfMonth == 1)
    }

    /// Weekdays belong to a weekly rule; carrying them elsewhere would make the
    /// summary text describe something that never fires.
    @Test func normalizationDropsWeekdaysFromNonWeeklyRules() {
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .monthly, interval: 1, weekdays: [2, 5]
        )
        #expect(rule.normalized().weekdays.isEmpty)
    }

    @Test func normalizationDropsAnOutOfRangeWeekday() {
        let rule = RecurrenceRule(
            mode: .onSchedule, frequency: .weekly, interval: 1, weekdays: [0, 3, 9]
        )
        #expect(rule.normalized().weekdays == [3])
    }

    // MARK: Summaries

    /// The sentence the row chip and the details section both show. It is the
    /// only description of the schedule a user ever reads, so it has to say
    /// what the rule actually does.
    @Test func summariesReadAsSentences() {
        let daily = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        #expect(daily.summary == "every day")

        let everyThreeDays = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 3)
        #expect(everyThreeDays.summary == "every 3 days")

        let monthly = RecurrenceRule(
            mode: .onSchedule, frequency: .monthly, interval: 1, dayOfMonth: 1
        )
        #expect(monthly.summary == "every month on the 1st")
    }

    @Test func aCompletionDrivenSummarySaysSo() {
        let rule = RecurrenceRule(mode: .afterCompletion, frequency: .daily, interval: 3)
        #expect(rule.summary == "3 days after the previous one is complete")
    }

    @Test func aWaitingScheduleSummarySaysBoth() {
        let rule = RecurrenceRule(
            mode: .afterCompletionOnSchedule, frequency: .weekly, interval: 1
        )
        #expect(rule.summary.contains("every week"))
        #expect(rule.summary.contains("once the previous one is complete"))
    }

    /// A paused series says so in the same sentence, since that chip is the
    /// only place the status is visible on a collapsed row.
    @Test func aPausedSummarySaysPaused() {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        rule.status = .paused
        #expect(rule.summary == "every day (paused)")
    }
}
