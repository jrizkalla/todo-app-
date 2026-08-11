import Testing
import Foundation
@testable import TODO

/// The expanded date vocabulary: weekday abbreviations, written-out dates, and
/// numeric forms.
///
/// Every test pins a reference date so the relative answers are deterministic.
/// The anchor is Monday 10 August 2026, chosen because it makes "next monday"
/// and "monday" genuinely different days — the case most likely to be wrong.
struct DatePhraseParserTests {

    /// The calendar every test reads and writes dates through.
    ///
    /// Pinned to UTC so the assertions do not shift with the machine's zone;
    /// the anchor below is built with this same calendar, since building it
    /// with a different one is how a "9am" expectation quietly becomes 3pm.
    private static let testCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Monday, 10 August 2026, noon UTC.
    private static let anchor: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 10
        components.hour = 12
        return testCalendar.date(from: components)!
    }()

    private var calendar: Calendar { Self.testCalendar }

    private var parser: DatePhraseParser {
        DatePhraseParser(referenceDate: Self.anchor, calendar: calendar)
    }

    /// The day/month/year of a match, for compact assertions.
    private func parts(_ match: DatePhraseMatch?) -> (year: Int, month: Int, day: Int)? {
        guard let match else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: match.date)
        return (components.year!, components.month!, components.day!)
    }

    // MARK: Weekday abbreviations

    @Test func detectsFullWeekday() {
        let result = parts(parser.parseWhole("friday"))
        // The Friday after Monday the 10th.
        #expect(result?.day == 14)
        #expect(result?.month == 8)
    }

    @Test(arguments: [
        ("mon", 17), ("tue", 11), ("tues", 11), ("wed", 12), ("weds", 12),
        ("thu", 13), ("thur", 13), ("thurs", 13), ("fri", 14), ("sat", 15), ("sun", 16),
    ])
    func detectsWeekdayAbbreviations(_ input: String, _ expectedDay: Int) {
        let result = parts(parser.parseWhole(input))
        #expect(result?.day == expectedDay, "\(input) should resolve to Aug \(expectedDay)")
    }

    /// A weekday naming today means the one a week out, not the day already
    /// underway — the anchor is itself a Monday.
    @Test func bareWeekdayMatchingTodayJumpsAWeek() {
        #expect(parts(parser.parseWhole("monday"))?.day == 17)
    }

    /// "next friday" is the week after the plain reading.
    @Test func nextQualifierAddsAWeek() {
        #expect(parts(parser.parseWhole("next friday"))?.day == 21)
    }

    @Test func weekdayCarriesATime() {
        guard let match = parser.parseWhole("weds at 3pm") else {
            Issue.record("expected a match")
            return
        }

        #expect(match.hasTime)
        #expect(calendar.component(.day, from: match.date) == 12)
        #expect(calendar.component(.hour, from: match.date) == 15)
    }

    // MARK: Written dates

    @Test(arguments: ["August 10", "august 10", "Aug 10", "aug 10", "aug 10th", "10 August", "10th of august"])
    func detectsWrittenDates(_ input: String) {
        let result = parts(parser.parseWhole(input))
        #expect(result?.month == 8, "\(input) should be August")
        #expect(result?.day == 10, "\(input) should be the 10th")
    }

    @Test func writtenDateWithExplicitYear() {
        let result = parts(parser.parseWhole("Aug 10, 2027"))
        #expect(result?.year == 2027)
        #expect(result?.month == 8)
        #expect(result?.day == 10)
    }

    /// A date already past this year means next year's.
    @Test func pastDateRollsToNextYear() {
        let result = parts(parser.parseWhole("March 3"))
        #expect(result?.year == 2027)
        #expect(result?.month == 3)
    }

    @Test func writtenDateWithTime() {
        guard let match = parser.parseWhole("August 12 at 9:30am") else {
            Issue.record("expected a match")
            return
        }

        #expect(match.hasTime)
        #expect(calendar.component(.hour, from: match.date) == 9)
        #expect(calendar.component(.minute, from: match.date) == 30)
    }

    /// A day the month does not have is not silently rolled into the next one.
    @Test func rejectsImpossibleDate() {
        #expect(parser.parseWhole("February 30") == nil)
    }

    // MARK: Numeric dates

    @Test func detectsISODate() {
        let result = parts(parser.parseWhole("2027-08-10"))
        #expect(result?.year == 2027)
        #expect(result?.month == 8)
        #expect(result?.day == 10)
    }

    /// A bare number in a date field is a day of the month.
    @Test func bareNumberIsDayOfMonth() {
        let result = parts(parser.parseWhole("15"))
        #expect(result?.month == 8)
        #expect(result?.day == 15)
    }

    /// A day already past means next month's.
    @Test func bareNumberInThePastRollsForward() {
        let result = parts(parser.parseWhole("3"))
        #expect(result?.month == 9)
        #expect(result?.day == 3)
    }

    // MARK: Relative phrases

    @Test func detectsToday() {
        #expect(parts(parser.parseWhole("today"))?.day == 10)
    }

    @Test func detectsTomorrow() {
        #expect(parts(parser.parseWhole("tomorrow"))?.day == 11)
    }

    /// "tonight" is today with an evening hour attached.
    @Test func tonightCarriesAnEveningTime() {
        guard let match = parser.parseWhole("tonight") else {
            Issue.record("expected a match")
            return
        }

        #expect(match.hasTime)
        #expect(calendar.component(.day, from: match.date) == 10)
        #expect(calendar.component(.hour, from: match.date) == 18)
    }

    @Test func detectsCountedDays() {
        #expect(parts(parser.parseWhole("in 3 days"))?.day == 13)
    }

    @Test func detectsCountedWeeks() {
        #expect(parts(parser.parseWhole("in 2 weeks"))?.day == 24)
    }

    // MARK: Bare days have no time

    @Test func bareDayIsMidnight() {
        guard let match = parser.parseWhole("aug 20") else {
            Issue.record("expected a match")
            return
        }

        #expect(match.hasTime == false)
        #expect(match.date == calendar.startOfDay(for: match.date))
    }

    // MARK: Matching inside a sentence

    /// The phrase is located within a longer title, so the caller can strip it.
    @Test func findsPhraseInsideATitle() {
        let matches = parser.matches(in: "Submit taxes aug 20")
        #expect(matches.count == 1)
        #expect(matches.first?.matchedText.lowercased() == "aug 20")
    }

    /// Overlapping engines must not report the same day twice.
    @Test func overlappingMatchesAreDeduplicated() {
        let matches = parser.matches(in: "Call mum next friday")
        #expect(matches.count == 1)
    }

    @Test func plainTextHasNoDates() {
        #expect(parser.matches(in: "Buy milk").isEmpty)
    }

    @Test func emptyInputParsesToNothing() {
        #expect(parser.parseWhole("") == nil)
        #expect(parser.parseWhole("   ") == nil)
    }

    /// A word that merely starts with a weekday abbreviation is not a date.
    @Test func doesNotMatchWeekdayInsideWord() {
        #expect(parser.matches(in: "Order satchel").isEmpty)
        #expect(parser.matches(in: "Read monday's report").isEmpty == false)
    }

    // MARK: Title parser integration

    /// The expanded vocabulary reaches the title chips, not just the field.
    @Test func titleParserOffersWeekdayAbbreviation() {
        var parser = TitleParser()
        parser.referenceDate = Self.anchor
        parser.calendar = calendar

        let suggestions = parser.suggestions(for: "Dentist weds")
        #expect(suggestions.contains { if case .schedule = $0.kind { true } else { false } })
        #expect(suggestions.allSatisfy { $0.matchedText.lowercased() == "weds" })
    }

    @Test func titleParserOffersWrittenDate() {
        var parser = TitleParser()
        parser.referenceDate = Self.anchor
        parser.calendar = calendar

        let suggestions = parser.suggestions(for: "Renew passport aug 20")
        #expect(suggestions.count == 2)

        for suggestion in suggestions {
            if case .schedule(let date, _) = suggestion.kind {
                #expect(calendar.component(.day, from: date) == 20)
            }
        }
    }
}
