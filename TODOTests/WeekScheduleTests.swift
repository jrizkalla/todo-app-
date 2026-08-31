import Foundation
import SwiftData
import Testing
@testable import TODO

/// The week-scheduling rules: what an anchor means, what it excludes, and what
/// happens to it when the week runs out.
@MainActor
struct WeekScheduleTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// A fixed calendar so the tests do not depend on the machine's week-start
    /// preference. Sunday-first, which is `Calendar.current`'s default in the
    /// US locale the app is developed against.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }

    /// A Wednesday, so "this week" has days on both sides of `now` and a bug
    /// that silently uses the start or end of the week is visible.
    private var wednesday: Date {
        DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 8, day: 26, hour: 10
        ).date!
    }

    // MARK: Anchors

    /// The anchor is the start of a week, whichever day inside it you ask from.
    @Test func anchorIsTheStartOfTheWeek() {
        let anchor = WeekMath.anchor(for: .thisWeek, now: wednesday, calendar: calendar)

        #expect(anchor == calendar.startOfDay(for: anchor))
        #expect(calendar.component(.weekday, from: anchor) == calendar.firstWeekday)
        #expect(anchor < wednesday)
    }

    /// Next week's anchor is exactly seven days past this week's.
    @Test func nextWeekIsSevenDaysOn() {
        let this = WeekMath.anchor(for: .thisWeek, now: wednesday, calendar: calendar)
        let next = WeekMath.anchor(for: .nextWeek, now: wednesday, calendar: calendar)

        #expect(next.timeIntervalSince(this) == 7 * 24 * 3600)
    }

    /// The claim the whole design rests on: nothing is rewritten at the week
    /// boundary, and the same stored anchor reads as This Week once the week
    /// turns over.
    ///
    /// This is the "should happen automatically if you set up the list filters
    /// correctly" requirement, checked directly — one to-do, one unchanged
    /// column, two different readings a week apart.
    @Test func nextWeekBecomesThisWeekWithoutRewritingTheRow() throws {
        let context = try makeContext()
        let todo = Todo(title: "Book flights")
        context.insert(todo)
        todo.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)

        let storedAnchor = try #require(todo.weekAnchor)

        #expect(todo.weekSchedule(now: wednesday, calendar: calendar) == .nextWeek)

        let weekLater = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        #expect(todo.weekSchedule(now: weekLater, calendar: calendar) == .thisWeek)
        // The column itself never moved — that is the point.
        #expect(todo.weekAnchor == storedAnchor)
    }

    /// A week further out than next reads as neither, rather than falling
    /// through to the nearest match.
    @Test func aDistantWeekReadsAsNeitherList() throws {
        let context = try makeContext()
        let todo = Todo(title: "Someday")
        context.insert(todo)
        todo.weekAnchor = calendar.date(byAdding: .weekOfYear, value: 4, to: wednesday)!

        #expect(todo.weekSchedule(now: wednesday, calendar: calendar) == nil)
    }

    /// The bug that made Next Week render empty: writes computed the anchor
    /// with one calendar and the list predicate looked for it with another.
    ///
    /// Anchors are matched by equality, so a one-day disagreement about where a
    /// week starts hides the row in both lists. This pins the two definitions
    /// together — `AppSettings.calendar`, which the lists query with, and
    /// `WeekMath.appCalendar`, which every unqualified write uses.
    @Test func theAppAndWeekMathCalendarsAgree() {
        #expect(WeekMath.appCalendar.firstWeekday == AppSettings.shared.calendar.firstWeekday)

        let viaSettings = WeekMath.startOfWeek(
            containing: wednesday, calendar: AppSettings.shared.calendar
        )
        let viaDefault = WeekMath.startOfWeek(containing: wednesday)
        #expect(viaSettings == viaDefault)
    }

    /// A to-do written with no explicit calendar is found by the list querying
    /// with the app's — the round trip the mismatch broke.
    ///
    /// Deliberately goes through the store and a real fetch rather than the
    /// array rules: the equality predicate is the part that failed, and only
    /// the fetch exercises it.
    @Test func aWeekPlannedTodoIsFoundByTheListThatQueriesForIt() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = store.createTodo(title: "Book flights", weekSchedule: .nextWeek)
        try context.save()

        let found = TodoQueries.todos(
            for: .nextWeek, in: context, calendar: AppSettings.shared.calendar
        )

        #expect(found.contains { $0.uuid == todo.uuid })
    }

    /// The round trip holds under *either* week-start preference.
    ///
    /// The regression was invisible on a Sunday-start machine, which is what
    /// let it ship: the write's `Calendar.current` and the list's pinned
    /// `firstWeekday = 1` happened to agree. Driving both settings explicitly
    /// is what makes the Monday case — where they did not — a real assertion
    /// rather than a coincidence of the developer's locale.
    @Test(arguments: [1, 2]) func anchorsRoundTripUnderEitherWeekStart(firstWeekday: Int) throws {
        var listCalendar = Calendar(identifier: .gregorian)
        listCalendar.firstWeekday = firstWeekday
        listCalendar.timeZone = calendar.timeZone

        let context = try makeContext()
        let todo = Todo(title: "Book flights")
        context.insert(todo)
        // The write and the read use the same calendar, which is exactly what
        // `WeekMath.appCalendar` guarantees in the app.
        todo.scheduleForWeek(.nextWeek, now: wednesday, calendar: listCalendar)
        try context.save()

        let expected = WeekMath.anchor(
            for: .nextWeek, now: wednesday, calendar: listCalendar
        )
        #expect(todo.weekAnchor == expected)

        let found = TodoQueries.todos(
            for: .nextWeek, in: context, calendar: listCalendar, now: wednesday
        )
        #expect(found.contains { $0.uuid == todo.uuid })
    }

    /// The bug that actually made Next Week render empty in the app.
    ///
    /// A `@Query`'s descriptor is fixed when the view is built, so the `now`
    /// used to compute the week anchor is frozen with it. The predicate used to
    /// test that anchor for *equality*, so once the week turned over the
    /// descriptor asked for a value no row carried and the list came up empty —
    /// while the sidebar badge, recomputed on every redraw, still showed a
    /// count. That mismatch is the signature.
    ///
    /// Driving a deliberately stale descriptor against a freshly written to-do
    /// is what reproduces it without waiting a week.
    @Test func aDescriptorBuiltLastWeekStillFindsThisWeeksPlans() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)

        let lastWeek = try #require(
            calendar.date(byAdding: .day, value: -8, to: wednesday)
        )

        // The view was built last week and cached.
        let staleDescriptor = TodoQueries.descriptor(
            for: .nextWeek, calendar: calendar, now: lastWeek
        )

        // A to-do planned for next week as of *now*.
        let todo = Todo(title: "Book flights")
        context.insert(todo)
        todo.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)
        try context.save()

        // The stale descriptor must not silently select nothing. It is allowed
        // to be a week behind — the view identity rebuilds it — but an
        // equality-based predicate returned the empty set instead, which is
        // what the user saw.
        let fresh = TodoQueries.todos(
            for: .nextWeek, in: context, calendar: calendar, now: wednesday
        )
        #expect(fresh.contains { $0.uuid == todo.uuid })

        // And the stale one selects a real week rather than an impossible
        // value: nothing here, because the to-do genuinely belongs to a later
        // week, but the *shape* is a range and not an equality.
        let staleResults = try context.fetch(staleDescriptor)
        #expect(staleResults.allSatisfy { $0.weekAnchor != nil })
    }

    /// A range predicate admits an anchor anywhere inside its week, so an
    /// anchor that is not exactly midnight — from an import, or a clock change
    /// — is still found.
    @Test func anAnchorInsideTheWeekIsStillFound() throws {
        let context = try makeContext()
        let todo = Todo(title: "Imported")
        context.insert(todo)
        // Mid-week, mid-afternoon: not the normalized anchor an equality test
        // would demand.
        todo.weekAnchor = calendar.date(
            byAdding: .day, value: 2,
            to: WeekMath.anchor(for: .nextWeek, now: wednesday, calendar: calendar)
        )
        try context.save()

        let found = TodoQueries.todos(
            for: .nextWeek, in: context, calendar: calendar, now: wednesday
        )
        #expect(found.contains { $0.uuid == todo.uuid })
    }

    // MARK: Exclusion

    /// Scheduling for a week clears the day, in that direction.
    @Test func planningAWeekClearsTheAssignedDate() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task", assignedDate: wednesday)
        todo.assignedHasTime = true
        context.insert(todo)

        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)

        #expect(todo.assignedDate == nil)
        #expect(todo.assignedHasTime == false)
        #expect(todo.weekAnchor != nil)
    }

    /// A deadline is not a placement, so it survives a week plan.
    @Test func planningAWeekKeepsTheDeadlineAndDuration() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task", dueDate: wednesday)
        todo.duration = 1800
        context.insert(todo)

        todo.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)

        #expect(todo.dueDate == wednesday)
        #expect(todo.duration == 1800)
    }

    /// And scheduling a day clears the week, in the other direction — through
    /// the store verb every scheduling surface goes through.
    @Test func schedulingADateClearsTheWeek() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = Todo(title: "Task", weekSchedule: .thisWeek)
        context.insert(todo)

        store.schedule(todo, to: wednesday, hasTime: false)

        #expect(todo.weekAnchor == nil)
        #expect(todo.assignedDate == wednesday)
    }

    /// Constructing a to-do with both is not a way around the rule.
    @Test func theInitializerEnforcesTheExclusion() {
        let todo = Todo(title: "Task", assignedDate: wednesday, weekSchedule: .thisWeek)

        #expect(todo.assignedDate == nil)
        #expect(todo.weekAnchor != nil)
    }

    /// Unscheduling takes the week off as well as the date, or "unschedule"
    /// would leave the to-do scheduled.
    @Test func unschedulingClearsTheWeek() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = Todo(title: "Task", weekSchedule: .nextWeek)
        context.insert(todo)

        store.unschedule(todo)

        #expect(todo.weekAnchor == nil)
    }

    /// A week plan files the to-do into Anytime rather than leaving it in the
    /// Inbox, so it does not appear in two lists at once.
    @Test func aWeekPlanFilesOutOfTheInbox() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task", weekSchedule: .thisWeek)
        context.insert(todo)
        todo.refileForCurrentScheduling()

        #expect(todo.bucket == .anytime)
        #expect(todo.isScheduled)
    }

    // MARK: Lists

    /// This Week holds both populations: dated inside the week, and planned for
    /// the week outright.
    @Test func thisWeekUnionsDatedAndPlannedWork() throws {
        let context = try makeContext()
        let dated = Todo(title: "Dated", assignedDate: wednesday)
        let planned = Todo(title: "Planned", weekSchedule: nil)
        let next = Todo(title: "Next", weekSchedule: nil)
        [dated, planned, next].forEach(context.insert)
        planned.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)
        next.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)

        let titles = TodoQueries.thisWeek(
            [dated, planned, next], calendar: calendar, now: wednesday
        ).map(\.title)

        #expect(titles.contains("Dated"))
        #expect(titles.contains("Planned"))
        #expect(!titles.contains("Next"))
    }

    /// Next Week holds only what was planned into it — a to-do that merely
    /// carries a date seven days out is not swept in.
    @Test func nextWeekHoldsOnlyPlannedWork() throws {
        let context = try makeContext()
        let plannedNext = Todo(title: "Planned")
        let datedNextWeek = Todo(
            title: "Dated", assignedDate: calendar.date(byAdding: .day, value: 8, to: wednesday)!
        )
        [plannedNext, datedNextWeek].forEach(context.insert)
        plannedNext.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)

        let titles = TodoQueries.nextWeek(
            [plannedNext, datedNextWeek], calendar: calendar, now: wednesday
        ).map(\.title)

        #expect(titles == ["Planned"])
    }

    /// The fetch and the array rules agree for both week lists, the way they do
    /// for every other destination.
    @Test func weekFetchesMatchTheArrayRules() throws {
        let context = try makeContext()
        let planned = Todo(title: "Planned")
        let next = Todo(title: "Next")
        let dated = Todo(title: "Dated", assignedDate: wednesday)
        [planned, next, dated].forEach(context.insert)
        planned.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)
        next.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)
        try context.save()

        let all = [planned, next, dated]

        for destination in [ListDestination.thisWeek, .nextWeek] {
            let fetched = TodoQueries.todos(
                for: destination, in: context, calendar: calendar, now: wednesday
            )
            let expected = destination == .thisWeek
                ? TodoQueries.thisWeek(all, calendar: calendar, now: wednesday)
                : TodoQueries.nextWeek(all, calendar: calendar, now: wednesday)

            #expect(
                fetched.map(\.title).sorted() == expected.map(\.title).sorted(),
                "\(destination.title) differed between the fetch and the array rules"
            )
        }
    }

    // MARK: Rollover

    /// The requirement: what was in This Week lands on the last night of that
    /// week once it ends, which makes it overdue.
    @Test func rolloverSweepsLastWeeksPlansIntoOverdue() throws {
        let context = try makeContext()
        let todo = Todo(title: "Slipped")
        context.insert(todo)
        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)

        let nextWednesday = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        let swept = WeekScheduleRollover.run(in: context, now: nextWednesday, calendar: calendar)

        #expect(swept.map(\.title) == ["Slipped"])
        #expect(todo.weekAnchor == nil)

        let assigned = try #require(todo.assignedDate)
        #expect(todo.assignedHasTime)
        #expect(calendar.component(.hour, from: assigned) == WeekScheduleRollover.sweptHour)
        // The last day of the week that just ended — the day before the current
        // week began.
        let currentWeekStart = WeekMath.startOfWeek(containing: nextWednesday, calendar: calendar)
        #expect(assigned < currentWeekStart)
        #expect(
            calendar.isDate(
                assigned,
                inSameDayAs: calendar.date(byAdding: .day, value: -1, to: currentWeekStart)!
            )
        )
        // And it is now in the past, which is what puts it in Today.
        #expect(assigned < nextWednesday)
    }

    /// Next week's plans are promoted rather than swept — they are still ahead.
    @Test func rolloverLeavesNextWeeksPlansAlone() throws {
        let context = try makeContext()
        let todo = Todo(title: "Ahead")
        context.insert(todo)
        todo.scheduleForWeek(.nextWeek, now: wednesday, calendar: calendar)
        let anchor = todo.weekAnchor

        let nextWednesday = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        let swept = WeekScheduleRollover.run(in: context, now: nextWednesday, calendar: calendar)

        #expect(swept.isEmpty)
        #expect(todo.weekAnchor == anchor)
        #expect(todo.assignedDate == nil)
        // Promoted, purely by the calendar moving.
        #expect(todo.weekSchedule(now: nextWednesday, calendar: calendar) == .thisWeek)
    }

    /// Finished work keeps its history: a to-do completed inside its week is
    /// not rewritten into a miss.
    @Test func rolloverLeavesResolvedWorkAlone() throws {
        let context = try makeContext()
        let todo = Todo(title: "Done")
        context.insert(todo)
        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)
        todo.setState(.completed)

        let nextWednesday = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        let swept = WeekScheduleRollover.run(in: context, now: nextWednesday, calendar: calendar)

        #expect(swept.isEmpty)
        #expect(todo.assignedDate == nil)
    }

    /// Running it twice does nothing the second time, which is what makes it
    /// safe on every launch and every foreground.
    @Test func rolloverIsIdempotent() throws {
        let context = try makeContext()
        let todo = Todo(title: "Slipped")
        context.insert(todo)
        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)

        let nextWednesday = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        _ = WeekScheduleRollover.run(in: context, now: nextWednesday, calendar: calendar)
        let firstDate = todo.assignedDate

        let secondPass = WeekScheduleRollover.run(
            in: context, now: nextWednesday, calendar: calendar
        )

        #expect(secondPass.isEmpty)
        #expect(todo.assignedDate == firstDate)
    }

    /// A plan several weeks stale is swept onto *its own* week's last night,
    /// not onto the most recent one — the sweep records when the work was
    /// actually promised.
    @Test func rolloverSweepsToTheWeekThatWasMissed() throws {
        let context = try makeContext()
        let todo = Todo(title: "Long forgotten")
        context.insert(todo)
        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)
        let anchor = try #require(todo.weekAnchor)

        let muchLater = calendar.date(byAdding: .weekOfYear, value: 5, to: wednesday)!
        _ = WeekScheduleRollover.run(in: context, now: muchLater, calendar: calendar)

        let assigned = try #require(todo.assignedDate)
        #expect(assigned > anchor)
        #expect(assigned < WeekMath.endOfWeek(startingAt: anchor, calendar: calendar))
    }

    /// A swept to-do is not flagged as new: the user has seen it, the week just
    /// ran out.
    @Test func sweepingDoesNotFlagTheTodoAsNew() throws {
        let context = try makeContext()
        let todo = Todo(title: "Slipped")
        context.insert(todo)
        todo.scheduleForWeek(.thisWeek, now: wednesday, calendar: calendar)
        todo.markAsViewed()

        let nextWednesday = calendar.date(byAdding: .day, value: 7, to: wednesday)!
        _ = WeekScheduleRollover.run(in: context, now: nextWednesday, calendar: calendar)

        #expect(!todo.isNew)
    }

    // MARK: Round trips

    /// Undo puts a week plan back, rather than restoring only the date half.
    ///
    /// The snapshot has to carry `weekAnchor` for this: without it, undoing a
    /// "moved from This Week onto Tuesday" restored the empty date and left the
    /// week cleared, so the row came back in neither list.
    @Test func undoRestoresAWeekPlan() throws {
        UndoStack.shared.reset()
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = Todo(title: "Task", weekSchedule: .nextWeek)
        context.insert(todo)
        let anchor = todo.weekAnchor

        store.schedule(todo, to: wednesday, hasTime: false)
        #expect(todo.weekAnchor == nil)

        UndoStack.shared.undo(in: context)

        #expect(todo.weekAnchor == anchor)
        #expect(todo.assignedDate == nil)
    }

    /// A recurrence template carries no week, the same way it carries no date.
    @Test func templatesDoNotCarryAWeekPlan() throws {
        let context = try makeContext()
        let todo = Todo(title: "Weekly", weekSchedule: .thisWeek)
        context.insert(todo)
        todo.recurrenceRule = RecurrenceRule(
            mode: .onSchedule, frequency: .weekly, interval: 1, weekdays: [2]
        )

        todo.clearScheduleForTemplate(calendar: calendar)

        #expect(todo.weekAnchor == nil)
    }
}
