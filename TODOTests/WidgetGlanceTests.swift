import Testing
import Foundation
import SwiftData
@testable import TODO

/// The two facts every glance-sized widget reduces the day to: what is next,
/// and how much of the day is done.
///
/// Three surfaces read these — the progress widget's small and medium bodies,
/// and the lock screen's inline line — and the point of testing the rules here
/// rather than in each widget is that all three must agree. A user seeing "Mon
/// 14 · Standup" above the clock and a different title on the home screen has
/// caught the app contradicting itself about its own day.
@MainActor
struct WidgetGlanceTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    private var calendar: Calendar { Calendar.current }

    /// A time on today, as a `Date`.
    private func today(at hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        )!
    }

    /// A timed to-do, which is what `assignedHasTime` turns on.
    private func timed(_ title: String, at date: Date, in context: ModelContext) -> Todo {
        let todo = Todo(title: title, assignedDate: date)
        todo.assignedHasTime = true
        context.insert(todo)
        return todo
    }

    private func untimed(_ title: String, in context: ModelContext) -> Todo {
        let todo = Todo(title: title, assignedDate: calendar.startOfDay(for: Date()))
        context.insert(todo)
        return todo
    }

    // MARK: Next up

    /// The next *scheduled* item wins while one is still to come, even when
    /// untimed work sits above it in manual order.
    @Test func nextUpPrefersTheComingAppointment() throws {
        let context = try makeContext()
        let loose = untimed("Water the plants", in: context)
        loose.sortIndex = 0
        let soon = timed("Standup", at: today(at: 14), in: context)

        let next = TodoQueries.widgetNextUp(
            [loose, soon], now: today(at: 13)
        )

        #expect(next?.title == "Standup")
    }

    /// Among several still to come, the earliest is the next one.
    @Test func nextUpTakesTheEarliestComingSlot() throws {
        let context = try makeContext()
        let later = timed("Retro", at: today(at: 17), in: context)
        let sooner = timed("Standup", at: today(at: 15), in: context)

        let next = TodoQueries.widgetNextUp([later, sooner], now: today(at: 13))

        #expect(next?.title == "Standup")
    }

    /// With nothing left on the clock, the first unscheduled item is next —
    /// "first" meaning the order the user arranged, not whichever the fetch
    /// happened to return.
    @Test func nextUpFallsBackToFirstUnscheduled() throws {
        let context = try makeContext()
        let second = untimed("Reply to Sam", in: context)
        second.sortIndex = 1
        let first = untimed("Water the plants", in: context)
        first.sortIndex = 0
        // Already over by `now`, so it cannot be the answer.
        let done = timed("Standup", at: today(at: 9), in: context)

        let next = TodoQueries.widgetNextUp([second, first, done], now: today(at: 13))

        #expect(next?.title == "Water the plants")
    }

    /// A slot that has passed is still named when it is all that is left: the
    /// day's one remaining task does not stop being next because it is late.
    @Test func nextUpNamesAPassedSlotWhenNothingElseRemains() throws {
        let context = try makeContext()
        let missed = timed("Standup", at: today(at: 9), in: context)

        let next = TodoQueries.widgetNextUp([missed], now: today(at: 13))

        #expect(next?.title == "Standup")
    }

    /// Finished work is never offered as the next thing to do — the progress
    /// widget fetches resolved rows to count them, and shares this list.
    @Test func nextUpSkipsResolvedWork() throws {
        let context = try makeContext()
        let done = timed("Standup", at: today(at: 14), in: context)
        done.setState(.completed)
        let open = untimed("Water the plants", in: context)

        let next = TodoQueries.widgetNextUp([done, open], now: today(at: 13))

        #expect(next?.title == "Water the plants")
    }

    /// An empty day has no next task, rather than a placeholder one.
    @Test func nextUpIsNilOnAnEmptyDay() throws {
        #expect(TodoQueries.widgetNextUp([], now: today(at: 13)) == nil)
    }

    // MARK: Progress

    /// Done over total, counted across the same rows the Today list draws.
    @Test func progressCountsResolvedOverAll() throws {
        let context = try makeContext()
        let a = untimed("A", in: context)
        let b = untimed("B", in: context)
        let c = untimed("C", in: context)
        a.setState(.completed)

        let progress = TodoQueries.widgetProgress([a, b, c])

        #expect(progress.done == 1)
        #expect(progress.total == 3)
    }

    /// Cancelled work counts as dealt with. Leaving it in the denominator only
    /// would strand a day the user has finished with short of full.
    @Test func progressCountsCancelledAsDone() throws {
        let context = try makeContext()
        let a = untimed("A", in: context)
        let b = untimed("B", in: context)
        a.setState(.cancelled)
        b.setState(.completed)

        let progress = TodoQueries.widgetProgress([a, b])

        #expect(progress.done == 2)
        #expect(progress.total == 2)
    }

    /// Projects are containers, not work: counting one would make a day with a
    /// single project and a single task read as half done before anything
    /// happened.
    @Test func progressIgnoresProjects() throws {
        let context = try makeContext()
        let project = Todo(title: "Move house", isProject: true)
        context.insert(project)
        let task = untimed("Book the van", in: context)

        let progress = TodoQueries.widgetProgress([project, task])

        #expect(progress.total == 1)
        #expect(progress.done == 0)
    }

    /// An empty day is not "0 of 0 done" dressed up as a fraction; the widget
    /// needs to be able to tell this case apart and say something else.
    @Test func progressOnAnEmptyDayHasNoTotal() throws {
        let progress = TodoQueries.widgetProgress([])

        #expect(progress.total == 0)
        #expect(progress.done == 0)
    }
}
