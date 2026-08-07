import Testing
import Foundation
@testable import TODO

/// Natural-language detection in the title field.
struct TitleParserTests {

    private var parser: TitleParser { TitleParser() }

    /// Helper: the first schedule suggestion, if any.
    private func scheduleDate(_ suggestions: [ParsedSuggestion]) -> (Date, Bool)? {
        for suggestion in suggestions {
            if case .schedule(let date, let hasTime) = suggestion.kind { return (date, hasTime) }
        }
        return nil
    }

    private func durationValue(_ suggestions: [ParsedSuggestion]) -> TimeInterval? {
        for suggestion in suggestions {
            if case .duration(let seconds) = suggestion.kind { return seconds }
        }
        return nil
    }

    // MARK: The spec's worked example

    /// "Clean car tomorrow" must surface exactly the two chips the spec names:
    /// a calendar "schedule" and a target "deadline".
    @Test func specExampleProducesScheduleAndDeadline() {
        let suggestions = parser.suggestions(for: "Clean car tomorrow")

        #expect(suggestions.count == 2)
        #expect(suggestions.contains { if case .schedule = $0.kind { true } else { false } })
        #expect(suggestions.contains { if case .deadline = $0.kind { true } else { false } })
        #expect(suggestions.allSatisfy { $0.matchedText.lowercased() == "tomorrow" })

        let icons = Set(suggestions.map(\.symbolName))
        #expect(icons == ["calendar", "target"])
    }

    /// Accepting a suggestion strips the matched word and leaves a clean title.
    @Test func acceptingSuggestionClearsMatchedText() {
        let title = "Clean car tomorrow"
        guard let suggestion = parser.suggestions(for: title).first else {
            Issue.record("expected a suggestion")
            return
        }

        #expect(TitleParser.removing(suggestion, from: title) == "Clean car")
    }

    /// Removing a match from the middle collapses the double space.
    @Test func removingMidTitleMatchTidiesWhitespace() {
        let title = "Call tomorrow about invoice"
        guard let suggestion = parser.suggestions(for: title).first else {
            Issue.record("expected a suggestion")
            return
        }

        #expect(TitleParser.removing(suggestion, from: title) == "Call about invoice")
    }

    // MARK: Relative dates

    @Test func detectsToday() {
        let result = scheduleDate(parser.suggestions(for: "Pay rent today"))
        #expect(result != nil)
        #expect(Calendar.current.isDateInToday(result!.0))
    }

    @Test func detectsTomorrow() {
        let result = scheduleDate(parser.suggestions(for: "Ship package tomorrow"))
        #expect(result != nil)
        #expect(Calendar.current.isDateInTomorrow(result!.0))
    }

    /// A bare day carries no time, so the date is normalized to midnight.
    @Test func bareDayHasNoTimeComponent() {
        guard let (date, hasTime) = scheduleDate(parser.suggestions(for: "Dentist tomorrow")) else {
            Issue.record("expected a date")
            return
        }

        #expect(hasTime == false)
        #expect(date == Calendar.current.startOfDay(for: date))
    }

    /// An explicit clock time is preserved and flagged.
    @Test func explicitTimeIsDetected() {
        guard let (date, hasTime) = scheduleDate(parser.suggestions(for: "Standup tomorrow at 9:30am")) else {
            Issue.record("expected a date")
            return
        }

        #expect(hasTime)
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        #expect(components.hour == 9)
        #expect(components.minute == 30)
    }

    // MARK: Durations

    @Test func detectsShorthandMinutes() {
        #expect(durationValue(parser.suggestions(for: "Stretch 5m")) == 300)
    }

    @Test func detectsSpelledOutMinutes() {
        #expect(durationValue(parser.suggestions(for: "Meditate 20 minutes")) == 1200)
    }

    @Test func detectsHours() {
        #expect(durationValue(parser.suggestions(for: "Deep work 2h")) == 7200)
    }

    @Test func detectsFractionalHours() {
        #expect(durationValue(parser.suggestions(for: "Workshop 1.5 hours")) == 5400)
    }

    /// A word-boundary guard keeps "5mm" from reading as five minutes.
    @Test func doesNotMatchDurationInsideWord() {
        #expect(durationValue(parser.suggestions(for: "Buy 5mm bolts")) == nil)
    }

    // MARK: Projects

    @Test func detectsKnownProjectName() {
        let id = UUID()
        var parser = TitleParser()
        parser.projectNames = [(name: "Kitchen", uuid: id)]

        let suggestions = parser.suggestions(for: "Paint Kitchen walls")
        let match = suggestions.first { if case .project = $0.kind { true } else { false } }

        #expect(match != nil)
        if case .project(let name, let uuid) = match?.kind {
            #expect(name == "Kitchen")
            #expect(uuid == id)
        }
    }

    /// Project matching is case-insensitive.
    @Test func projectMatchIgnoresCase() {
        var parser = TitleParser()
        parser.projectNames = [(name: "Kitchen", uuid: UUID())]

        let suggestions = parser.suggestions(for: "paint kitchen walls")
        #expect(suggestions.contains { if case .project = $0.kind { true } else { false } })
    }

    /// A project name must match a whole word, not a fragment.
    @Test func projectDoesNotMatchSubstring() {
        var parser = TitleParser()
        parser.projectNames = [(name: "Car", uuid: UUID())]

        let suggestions = parser.suggestions(for: "Buy cardboard")
        #expect(suggestions.contains { if case .project = $0.kind { true } else { false } } == false)
    }

    /// Unknown project names produce nothing.
    @Test func unknownProjectIsIgnored() {
        let suggestions = parser.suggestions(for: "Paint Kitchen walls")
        #expect(suggestions.contains { if case .project = $0.kind { true } else { false } } == false)
    }

    // MARK: Negative cases

    @Test func plainTitleProducesNoSuggestions() {
        #expect(parser.suggestions(for: "Buy milk").isEmpty)
    }

    @Test func emptyTitleProducesNoSuggestions() {
        #expect(parser.suggestions(for: "").isEmpty)
        #expect(parser.suggestions(for: "   ").isEmpty)
    }

    /// A title carrying both a date and a duration offers all three chips.
    @Test func combinedDateAndDuration() {
        let suggestions = parser.suggestions(for: "Gym tomorrow 45m")

        #expect(scheduleDate(suggestions) != nil)
        #expect(durationValue(suggestions) == 2700)
    }

    // MARK: Labels

    @Test func labelsReadNaturally() {
        let suggestions = parser.suggestions(for: "Clean car tomorrow")
        let labels = Set(suggestions.map(\.label))
        #expect(labels == ["Schedule tomorrow", "Deadline tomorrow"])
    }

    @Test func durationLabelFormatsHoursAndMinutes() {
        #expect(ParsedSuggestion.describe(duration: 300) == "5m")
        #expect(ParsedSuggestion.describe(duration: 3600) == "1h")
        #expect(ParsedSuggestion.describe(duration: 5400) == "1h 30m")
    }
}
