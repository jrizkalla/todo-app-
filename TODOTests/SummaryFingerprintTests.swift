import Testing
import Foundation
@testable import TODO

/// The rules that decide whether a cached AI summary still describes the day.
///
/// The fingerprint exists to answer one question — "would the model have seen
/// something different?" — so these tests are all shaped the same way: build a
/// fingerprint, change one input, and assert whether that counts.
@MainActor
struct SummaryFingerprintTests {

    private func todo(
        title: String = "Task",
        notes: String = "",
        state: CompletionState? = nil,
        assignedDate: Date? = nil,
        assignedHasTime: Bool = false,
        duration: TimeInterval? = nil,
        dueDate: Date? = nil,
        dueHasTime: Bool = false,
        isProject: Bool = false,
        parentTitle: String? = nil
    ) -> TodoStruct {
        .init(
            title: title,
            notes: notes,
            state: state,
            assignedDate: assignedDate,
            assignedHasTime: assignedHasTime,
            duration: duration,
            dueDate: dueDate,
            dueHasTime: dueHasTime,
            isProject: isProject,
            space: nil,
            parentTitle: parentTitle
        )
    }

    private func event(
        id: String = "1",
        title: String = "Meeting",
        start: Date = Date(timeIntervalSince1970: 1_000_000),
        end: Date = Date(timeIntervalSince1970: 1_003_600),
        isAllDay: Bool = false,
        calendarTitle: String = "Work",
        location: String? = nil
    ) -> CalendarEvent {
        .init(
            id: id,
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            calendarTitle: calendarTitle,
            colorHex: "#FFFFFF",
            location: location
        )
    }

    private func forecast(
        temperatureMax: [Double] = [20],
        precipitation: [Int?] = [10]
    ) -> WeatherForecast {
        // Built by hand rather than interpolating the arrays directly: Swift's
        // description of `[Int?]` renders as `[Optional(10)]`, which is not JSON.
        let maxes = temperatureMax.map { "\($0)" }.joined(separator: ",")
        let precip = precipitation.map { $0.map { "\($0)" } ?? "null" }.joined(separator: ",")
        let json = """
        {
          "latitude": 1.5,
          "longitude": 2.5,
          "timezone": "America/New_York",
          "daily": {
            "time": ["2026-08-11"],
            "temperature_2m_max": [\(maxes)],
            "temperature_2m_min": [10.0],
            "precipitation_probability_max": [\(precip)]
          }
        }
        """
        return try! JSONDecoder().decode(WeatherForecast.self, from: Data(json.utf8))
    }

    // MARK: Todos

    /// The same list twice is the same fingerprint — otherwise nothing would
    /// ever be reused.
    @Test func identicalTodosMatch() {
        let list = RelevantTodoList(scheduled: [todo()], overdue: [])
        #expect(SummaryFingerprint.todos(list) == SummaryFingerprint.todos(list))
    }

    @Test func addingATodoChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo(title: "A")], overdue: [])
        let after = RelevantTodoList(scheduled: [todo(title: "A"), todo(title: "B")], overdue: [])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    @Test func removingATodoChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo(title: "A"), todo(title: "B")], overdue: [])
        let after = RelevantTodoList(scheduled: [todo(title: "A")], overdue: [])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    /// Completing something is the change most likely to happen while the
    /// summary is on screen, so it has to invalidate.
    @Test func changingTodoStateChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo(state: .open)], overdue: [])
        let after = RelevantTodoList(scheduled: [todo(state: .completed)], overdue: [])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    @Test func changingTodoDueDateChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo(dueDate: Date(timeIntervalSince1970: 0))], overdue: [])
        let after = RelevantTodoList(scheduled: [todo(dueDate: Date(timeIntervalSince1970: 90_000))], overdue: [])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    @Test func changingTodoNotesChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo(notes: "old")], overdue: [])
        let after = RelevantTodoList(scheduled: [todo(notes: "new")], overdue: [])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    /// The same to-do moving from scheduled to overdue is a different prompt,
    /// even though the item itself is untouched.
    @Test func movingATodoBetweenBucketsChangesTheFingerprint() {
        let before = RelevantTodoList(scheduled: [todo()], overdue: [])
        let after = RelevantTodoList(scheduled: [], overdue: [todo()])
        #expect(SummaryFingerprint.todos(before) != SummaryFingerprint.todos(after))
    }

    // MARK: Events

    @Test func addingAnEventChangesTheFingerprint() {
        let before = SummaryFingerprint.events([event(id: "1")])
        let after = SummaryFingerprint.events([event(id: "1"), event(id: "2", title: "Other")])
        #expect(before != after)
    }

    @Test func changingAnEventTimeChangesTheFingerprint() {
        let before = SummaryFingerprint.events([event()])
        let after = SummaryFingerprint.events([event(start: Date(timeIntervalSince1970: 1_007_200))])
        #expect(before != after)
    }

    @Test func changingAnEventLocationChangesTheFingerprint() {
        let before = SummaryFingerprint.events([event(location: nil)])
        let after = SummaryFingerprint.events([event(location: "Office")])
        #expect(before != after)
    }

    /// The same events arriving in a different order is not a change the model
    /// would notice, and re-running on it would burn a generation for nothing.
    @Test func reorderingEventsDoesNotChangeTheFingerprint() {
        let a = event(id: "1", title: "A")
        let b = event(id: "2", title: "B")
        #expect(SummaryFingerprint.events([a, b]) == SummaryFingerprint.events([b, a]))
    }

    // MARK: Weather

    @Test func changingTheForecastChangesTheFingerprint() {
        let before = SummaryFingerprint.weather(forecast(temperatureMax: [20]))
        let after = SummaryFingerprint.weather(forecast(temperatureMax: [31]))
        #expect(before != after)
    }

    @Test func changingPrecipitationChangesTheFingerprint() {
        let before = SummaryFingerprint.weather(forecast(precipitation: [10]))
        let after = SummaryFingerprint.weather(forecast(precipitation: [90]))
        #expect(before != after)
    }

    /// Weather arriving after a summary was generated without it has to
    /// invalidate: dressing advice is the main thing the forecast drives.
    @Test func forecastArrivingChangesTheFingerprint() {
        #expect(SummaryFingerprint.weather(nil) != SummaryFingerprint.weather(forecast()))
    }

    // MARK: User info

    @Test func changingUserInfoChangesTheFingerprint() {
        let before = SummaryFingerprint.user(.init(name: "John", generalInfomation: nil, memory: nil))
        let after = SummaryFingerprint.user(.init(name: "Jane", generalInfomation: nil, memory: nil))
        #expect(before != after)
    }

    @Test func changingUserMemoryChangesTheFingerprint() {
        let before = SummaryFingerprint.user(.init(name: "John", generalInfomation: nil, memory: "a"))
        let after = SummaryFingerprint.user(.init(name: "John", generalInfomation: nil, memory: "b"))
        #expect(before != after)
    }

    // MARK: Whole-fingerprint rules

    /// The point of the whole exercise: the clock moving is not a reason to
    /// re-run the model.
    @Test func timePassingAloneDoesNotChangeTheFingerprint() {
        let service = AISummaryService(userInfo: .init(name: "John"))
        service.weather = forecast()
        service.reminders = .init(scheduled: [todo()], overdue: [])

        let morning = Date(timeIntervalSince1970: 1_754_900_000)
        // Same slot of the day, so the instructions are identical too — only
        // the clock has moved.
        let aMinuteLater = morning.addingTimeInterval(60)

        #expect(service.fingerprint(now: morning) == service.fingerprint(now: aMinuteLater))
    }

    /// Instructions are part of the prompt, so editing them — or crossing into
    /// a time of day that uses different ones — has to re-run.
    @Test func differentInstructionsChangeTheFingerprint() {
        var a = SummaryFingerprint()
        var b = SummaryFingerprint()
        a.instructions = AISummaryService.getInstructions(for: SummaryPhase.morning)
        b.instructions = AISummaryService.getInstructions(for: SummaryPhase.night)

        #expect(a.instructions != b.instructions)
        #expect(!a.matches(b))
    }

    /// A summary saved before fingerprints existed decodes with the empty
    /// default, which must not be mistaken for a match.
    @Test func emptyFingerprintDoesNotMatchAPopulatedOne() {
        var populated = SummaryFingerprint()
        populated.todos = ["something"]
        #expect(!SummaryFingerprint().matches(populated))
    }

    // MARK: Phase selection

    /// Hours chosen to sit inside `TimeOfDay`'s morning and afternoon bands.
    private func at(hour: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_754_900_000)
        )!
    }

    @Test func morningWithWorkLeftGetsTheMorningBrief() {
        #expect(SummaryPhase.from(date: at(hour: 8), remaining: 5) == .morning)
    }

    @Test func afternoonWithPlentyLeftGetsMidday() {
        #expect(SummaryPhase.from(date: at(hour: 14), remaining: 5) == .midday)
    }

    /// "Only 1 or 2 tasks/calendar events left" is the evening instructions.
    @Test func windingDownGetsEvening() {
        #expect(SummaryPhase.from(date: at(hour: 14), remaining: 2) == .evening)
        #expect(SummaryPhase.from(date: at(hour: 14), remaining: 1) == .evening)
    }

    @Test func threeRemainingIsStillMidday() {
        #expect(SummaryPhase.from(date: at(hour: 14), remaining: 3) == .midday)
    }

    @Test func nothingLeftGetsNight() {
        #expect(SummaryPhase.from(date: at(hour: 14), remaining: 0) == .night)
    }

    /// An empty day should talk about tomorrow even at 8am — there is no
    /// "how to prepare" brief to give for a day with nothing in it.
    @Test func emptyDayGetsNightEvenInTheMorning() {
        #expect(SummaryPhase.from(date: at(hour: 8), remaining: 0) == .night)
    }

    /// The morning brief wins over winding-down: a day with one thing in it
    /// still deserves the how-to-prepare framing when it has not started.
    @Test func morningOutranksWindingDown() {
        #expect(SummaryPhase.from(date: at(hour: 8), remaining: 1) == .morning)
    }

    /// Every phase must produce distinct instructions, or the fingerprint could
    /// not tell them apart and crossing a boundary would not re-run.
    @Test func everyPhaseHasDistinctInstructions() {
        let all = SummaryPhase.allCases.map { AISummaryService.getInstructions(for: $0) }
        #expect(Set(all).count == SummaryPhase.allCases.count)
        for instructions in all {
            #expect(instructions.contains("quickSummary"))
        }
    }

    /// Tomorrow's items are part of the prompt once the day winds down, so
    /// changing them has to invalidate.
    @Test func changingTomorrowChangesTheFingerprint() {
        let before = SummaryFingerprint.tomorrow([todo(title: "A")])
        let after = SummaryFingerprint.tomorrow([todo(title: "A"), todo(title: "B")])
        #expect(before != after)
    }

    /// A to-do tomorrow is not the same prompt as the same to-do today.
    @Test func tomorrowAndTodayAreDistinguished() {
        let list = RelevantTodoList(scheduled: [todo(title: "A")], overdue: [])
        #expect(SummaryFingerprint.todos(list) != SummaryFingerprint.tomorrow([todo(title: "A")]))
    }

    /// It survives the round trip through the SwiftData store as a value.
    @Test func fingerprintRoundTripsThroughCoding() throws {
        var original = SummaryFingerprint()
        original.instructions = "instructions"
        original.user = ["name: John"]
        original.weather = ["2026-08-11: 10.0-20.0 p10"]
        original.todos = ["scheduled|todo|Task"]
        original.events = ["1|Meeting"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SummaryFingerprint.self, from: data)
        #expect(decoded == original)
    }
}
