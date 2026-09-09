import Testing
import Foundation
import SwiftData
@testable import TODO

/// Duplicating a container, and the orders the widget and the sidebar impose.
@MainActor
struct DuplicationAndOrderingTests {

    private func makeStore() throws -> TodoStore {
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    // MARK: Duplication

    /// The reported bug: a duplicated project arrived without its checklist.
    @Test func duplicatingAProjectCopiesItsSubtasks() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        _ = store.addSubtask(to: project, title: "Book the venue")
        _ = store.addSubtask(to: project, title: "Send invites")

        let copy = store.duplicate(project)

        #expect(copy.title == "Launch")
        #expect(copy.isProject)
        #expect(copy.orderedSubtasks.map(\.title) == ["Book the venue", "Send invites"])
        // Copies, not the originals moved across.
        #expect(project.orderedSubtasks.count == 2)
        #expect(Set(copy.orderedSubtasks.map(\.uuid))
            .isDisjoint(with: Set(project.orderedSubtasks.map(\.uuid))))
    }

    /// A subtask can be a project itself, so the copy has to recurse.
    @Test func duplicatingCopiesNestedProjects() throws {
        let store = try makeStore()
        let outer = store.createTodo(title: "Outer", isProject: true)
        let inner = store.addSubtask(to: outer, title: "Inner")
        inner.isProject = true
        _ = store.addSubtask(to: inner, title: "Deep")

        let copy = store.duplicate(outer)

        let copiedInner = try #require(copy.orderedSubtasks.first)
        #expect(copiedInner.title == "Inner")
        #expect(copiedInner.orderedSubtasks.map(\.title) == ["Deep"])
    }

    /// Duplicating finished work is how it gets done again, so the copy — and
    /// everything under it — starts open.
    @Test func duplicatedSubtasksStartOpen() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let subtask = store.addSubtask(to: project, title: "Book the venue")
        store.setStateCascading(subtask, to: .completed)

        let copy = store.duplicate(project)

        #expect(copy.state == .open)
        #expect(copy.orderedSubtasks.allSatisfy { $0.state == .open })
    }

    @Test func duplicatingAPlainTodoStillCopiesIt() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        let copy = store.duplicate(todo)

        #expect(copy.title == "Milk")
        #expect(copy.uuid != todo.uuid)
        #expect(copy.orderedSubtasks.isEmpty)
    }

    // MARK: Widget ordering

    private func timed(_ store: TodoStore, _ title: String, at date: Date, duration: TimeInterval? = nil) -> Todo {
        let todo = store.createTodo(title: title, assignedDate: date)
        todo.assignedHasTime = true
        todo.duration = duration
        return todo
    }

    /// Timed work by the clock, then untimed work, then passed slots.
    @Test func widgetOrdersByTimeThenUntimed() throws {
        let store = try makeStore()
        let now = Date()

        let past = timed(store, "Past", at: now.addingTimeInterval(-3 * 3600))
        let later = timed(store, "Later", at: now.addingTimeInterval(5 * 3600))
        let unscheduled = store.createTodo(title: "Unscheduled", assignedDate: now)
        let current = timed(store, "Now", at: now.addingTimeInterval(-60), duration: 3600)
        let soon = timed(store, "Soon", at: now.addingTimeInterval(20 * 60))

        let ordered = TodoQueries.widgetOrdered(
            [past, later, unscheduled, current, soon], now: now
        )

        #expect(ordered.map(\.title) == ["Now", "Soon", "Later", "Unscheduled", "Past"])
    }

    /// Timed items sort by their actual time, not by which hour band they fall
    /// in — the ordering the bands used to approximate.
    @Test func widgetSortsTimedWorkByTheClock() throws {
        let store = try makeStore()
        let now = Date()

        let inFive = timed(store, "In five hours", at: now.addingTimeInterval(5 * 3600))
        let inTwenty = timed(store, "In twenty minutes", at: now.addingTimeInterval(20 * 60))
        let inTwo = timed(store, "In two hours", at: now.addingTimeInterval(2 * 3600))

        let ordered = TodoQueries.widgetOrdered([inFive, inTwenty, inTwo], now: now)

        #expect(ordered.map(\.title) == [
            "In twenty minutes", "In two hours", "In five hours"
        ])
    }

    /// Untimed work sits behind every upcoming slot, however far off.
    @Test func untimedWorkFollowsTimedWork() throws {
        let store = try makeStore()
        let now = Date()

        let untimed = store.createTodo(title: "Untimed", assignedDate: now)
        let lateInTheDay = timed(store, "Late", at: now.addingTimeInterval(8 * 3600))

        let ordered = TodoQueries.widgetOrdered([untimed, lateInTheDay], now: now)

        #expect(ordered.map(\.title) == ["Late", "Untimed"])
    }

    /// An item with no duration stops being "now" once its default slot runs
    /// out, rather than staying current for the rest of the day.
    @Test func untimedDurationFallsBackToTheNowWindow() throws {
        let store = try makeStore()
        let now = Date()

        let justStarted = timed(store, "Just started", at: now.addingTimeInterval(-60))
        let longDone = timed(store, "Long done", at: now.addingTimeInterval(-3600))

        #expect(TodoQueries.widgetRank(for: justStarted, now: now) == .upcoming)
        #expect(TodoQueries.widgetRank(for: longDone, now: now) == .past)
    }

    /// A due date is not a schedule, so a due-dated item ranks as unscheduled.
    @Test func dueDateAloneIsUnscheduled() throws {
        let store = try makeStore()
        let now = Date()
        let todo = store.createTodo(title: "Due", dueDate: now.addingTimeInterval(3600))

        #expect(TodoQueries.widgetRank(for: todo, now: now) == .unscheduled)
    }

    // MARK: Week list ordering

    private func weekStore() throws -> (TodoStore, Calendar, Date, Date) {
        let store = try makeStore()
        let cal = Calendar.current
        let now = Date()
        let midWeek = cal.dateInterval(of: .weekOfYear, for: now)!
            .start.addingTimeInterval(3 * 86400)
        return (store, cal, now, midWeek)
    }

    /// This Week leads with the work the user put there on purpose.
    ///
    /// The undated rows are the ones planned for the week itself rather than
    /// for a day in it; sorting them under the dated ones buried the deliberate
    /// choices beneath everything that merely carried a date — on This Week,
    /// that includes overdue work reaching back indefinitely.
    @Test func thisWeekLeadsWithUndatedWork() throws {
        let (store, cal, now, midWeek) = try weekStore()

        _ = store.createTodo(title: "Dated", assignedDate: midWeek)
        _ = store.createTodo(title: "Overdue", assignedDate: now.addingTimeInterval(-10 * 86400))
        _ = store.createTodo(title: "Planned", weekSchedule: .thisWeek)

        let rows = try store.context.fetch(
            TodoQueries.descriptor(for: .thisWeek, calendar: cal, includeResolved: false)
        )
        let ordered = TodoQueries.finish(rows, for: .thisWeek)

        #expect(ordered.first?.title == "Planned")
        #expect(ordered.map(\.title) == ["Planned", "Overdue", "Dated"])
    }

    /// A due date is a deadline, not a day to act on, so a to-do carrying only
    /// one has not been placed in the week and leads with the undated rows.
    @Test func aDueDateAloneDoesNotCountAsDated() throws {
        let (store, cal, _, midWeek) = try weekStore()

        _ = store.createTodo(title: "Dated", assignedDate: midWeek)
        let dueOnly = store.createTodo(title: "Due only", weekSchedule: .thisWeek)
        dueOnly.dueDate = midWeek

        let rows = try store.context.fetch(
            TodoQueries.descriptor(for: .thisWeek, calendar: cal, includeResolved: false)
        )
        let ordered = TodoQueries.finish(rows, for: .thisWeek)

        #expect(ordered.map(\.title) == ["Due only", "Dated"])
    }

    /// Next Week follows the same rule, and a row that acquires a day keeps it
    /// behind the ones still planned for the week at large.
    ///
    /// Next Week holds only week-anchored rows, so its dated population arrives
    /// the one way it can: a to-do given a day *after* being planned for the
    /// week. Setting the date is what clears the anchor — the two are mutually
    /// exclusive by design — so this reaches the list through its date.
    @Test func nextWeekLeadsWithUndatedWork() throws {
        let (store, cal, now, _) = try weekStore()

        let planned = store.createTodo(title: "Planned", weekSchedule: .nextWeek)
        let dated = store.createTodo(title: "Dated", weekSchedule: .nextWeek)
        let anchor = dated.weekAnchor!
        dated.assignedDate = cal.startOfDay(for: anchor).addingTimeInterval(2 * 86400)

        #expect(planned.assignedDate == nil)

        let ordered = TodoQueries.nextWeek(
            [planned, dated], calendar: cal, now: now, includeResolved: false
        )

        #expect(ordered.map(\.title) == ["Planned", "Dated"])
    }

    /// Dated rows still run in day order behind the undated ones.
    @Test func datedWeekWorkKeepsDayOrder() throws {
        let (store, cal, now, _) = try weekStore()
        let week = cal.dateInterval(of: .weekOfYear, for: now)!

        _ = store.createTodo(title: "Friday", assignedDate: week.start.addingTimeInterval(5 * 86400))
        _ = store.createTodo(title: "Tuesday", assignedDate: week.start.addingTimeInterval(2 * 86400))
        _ = store.createTodo(title: "Planned", weekSchedule: .thisWeek)

        let rows = try store.context.fetch(
            TodoQueries.descriptor(for: .thisWeek, calendar: cal, includeResolved: false)
        )
        let ordered = TodoQueries.finish(rows, for: .thisWeek)

        #expect(ordered.map(\.title) == ["Planned", "Tuesday", "Friday"])
    }

    /// The day lists are untouched: there, a time is the point and undated work
    /// is the remainder.
    @Test func todayStillLeadsWithDatedWork() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let now = Date()

        let dated = store.createTodo(title: "Dated", assignedDate: now)
        dated.assignedHasTime = true
        _ = store.createTodo(title: "Undated", assignedDate: cal.startOfDay(for: now))

        let rows = try store.context.fetch(
            TodoQueries.descriptor(for: .today, calendar: cal, includeResolved: false)
        )
        let ordered = TodoQueries.finish(rows, for: .today)

        #expect(ordered.first?.title == "Undated")
    }

    // MARK: Sidebar

    /// A finished project is not somewhere to file work, so it leaves the
    /// sidebar; the Logbook is where it stays reachable.
    @Test func completedProjectsLeaveTheSidebar() throws {
        let store = try makeStore()
        let space = store.createSpace(name: "Work")
        let open = store.createTodo(title: "Open", space: space, isProject: true)
        let done = store.createTodo(title: "Done", space: space, isProject: true)
        store.setStateCascading(done, to: .completed)

        let listed = TodoQueries.projects(inSpace: space.uuid, in: store.context)
        #expect(listed.map(\.uuid) == [open.uuid])

        // Still fetchable when a caller asks for everything.
        let all = TodoQueries.projects(
            inSpace: space.uuid, in: store.context, includeResolved: true
        )
        #expect(all.count == 2)
    }
}
