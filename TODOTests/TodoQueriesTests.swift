import Testing
import Foundation
import SwiftData
@testable import TODO

/// Filtering behind each sidebar destination.
@MainActor
struct TodoQueriesTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    private var calendar: Calendar { Calendar.current }

    private func day(offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
    }

    // MARK: Inbox

    /// The Inbox holds unfiled, undated, unresolved work only.
    @Test func inboxHoldsOnlyUnfiledWork() throws {
        let context = try makeContext()
        let loose = Todo(title: "Loose")
        let dated = Todo(title: "Dated", assignedDate: day(offset: 0))
        let done = Todo(title: "Done")
        [loose, dated, done].forEach(context.insert)
        done.setState(.completed)

        let inbox = TodoQueries.inbox([loose, dated, done])

        #expect(inbox.map(\.title) == ["Loose"])
    }

    /// Subtasks never appear as their own Inbox rows.
    @Test func inboxExcludesSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        [parent, child].forEach(context.insert)
        parent.addSubtask(child)

        #expect(TodoQueries.inbox([parent, child]).map(\.title) == ["Parent"])
    }

    /// Projects are sidebar entries, not Inbox rows.
    @Test func inboxExcludesProjects() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        context.insert(project)

        #expect(TodoQueries.inbox([project]).isEmpty)
    }

    // MARK: Today

    /// Today covers work scheduled or due today.
    @Test func todayIncludesTodaysWork() throws {
        let context = try makeContext()
        let todayTodo = Todo(title: "Today", assignedDate: day(offset: 0))
        let tomorrowTodo = Todo(title: "Tomorrow", assignedDate: day(offset: 1))
        [todayTodo, tomorrowTodo].forEach(context.insert)

        let result = TodoQueries.today([todayTodo, tomorrowTodo], calendar: calendar)

        #expect(result.map(\.title) == ["Today"])
    }

    /// Overdue work stays in Today so it cannot slip past unnoticed.
    @Test func todayIncludesOverdueWork() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -3))
        context.insert(overdue)

        #expect(TodoQueries.today([overdue], calendar: calendar).map(\.title) == ["Overdue"])
    }

    /// A due date alone puts an item in Today.
    @Test func todayIncludesItemsDueToday() throws {
        let context = try makeContext()
        let due = Todo(title: "Due", dueDate: day(offset: 0))
        context.insert(due)

        #expect(TodoQueries.today([due], calendar: calendar).map(\.title) == ["Due"])
    }

    @Test func todayExcludesResolvedWork() throws {
        let context = try makeContext()
        let done = Todo(title: "Done", assignedDate: day(offset: 0))
        context.insert(done)
        done.setState(.completed)

        #expect(TodoQueries.today([done], calendar: calendar).isEmpty)
    }

    // MARK: Any Time

    /// The summary's Any Time card and the home screen widget both list work
    /// with no time of day. Timed work belongs on the schedule grid, and
    /// showing it in both places would list the same to-do twice on one screen.
    @Test func untimedTodayExcludesTimedWork() throws {
        let context = try makeContext()
        let timed = Todo(title: "Timed", assignedDate: day(offset: 0))
        timed.assignedHasTime = true
        let untimed = Todo(title: "Untimed", assignedDate: day(offset: 0))
        [timed, untimed].forEach(context.insert)

        let result = TodoQueries.untimedToday([timed, untimed], calendar: calendar)

        #expect(result.map(\.title) == ["Untimed"])
    }

    /// Built on `today`, so overdue work is carried along with it — an untimed
    /// to-do from last week is still something to do at any point today.
    @Test func untimedTodayKeepsOverdueWork() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -3))
        context.insert(overdue)

        #expect(
            TodoQueries.untimedToday([overdue], calendar: calendar).map(\.title) == ["Overdue"]
        )
    }

    // MARK: This week

    /// A date beyond the current week falls outside This Week.
    @Test func thisWeekExcludesLaterDates() throws {
        let context = try makeContext()
        let soon = Todo(title: "Soon", assignedDate: day(offset: 0))
        let later = Todo(title: "Later", assignedDate: day(offset: 30))
        [soon, later].forEach(context.insert)

        let result = TodoQueries.thisWeek([soon, later], calendar: calendar)

        #expect(result.contains { $0.title == "Soon" })
        #expect(result.contains { $0.title == "Later" } == false)
    }

    // MARK: Logbook and overdue

    /// The logbook collects both completed and cancelled work.
    @Test func logbookHoldsResolvedWork() throws {
        let context = try makeContext()
        let done = Todo(title: "Done")
        let cancelled = Todo(title: "Cancelled")
        let open = Todo(title: "Open")
        [done, cancelled, open].forEach(context.insert)
        done.setState(.completed)
        cancelled.setState(.cancelled)

        let logbook = TodoQueries.logbook([done, cancelled, open])

        #expect(logbook.count == 2)
        #expect(logbook.contains { $0.title == "Open" } == false)
    }

    @Test func overdueListsPastDueUnresolvedWork() throws {
        let context = try makeContext()
        let late = Todo(title: "Late", dueDate: Date().addingTimeInterval(-7200))
        let future = Todo(title: "Future", dueDate: Date().addingTimeInterval(7200))
        [late, future].forEach(context.insert)

        #expect(TodoQueries.overdue([late, future]).map(\.title) == ["Late"])
    }

    // MARK: Calendar splitting

    /// The calendar separates all-day items from timed ones, which land in the
    /// header and the grid respectively.
    @Test func calendarSplitsTimedFromUntimed() throws {
        let context = try makeContext()
        let today = calendar.startOfDay(for: Date())

        let allDay = Todo(title: "All day", assignedDate: today)
        let timed = Todo(title: "Timed", assignedDate: today.addingTimeInterval(10 * 3600))
        timed.assignedHasTime = true
        [allDay, timed].forEach(context.insert)

        let todos = [allDay, timed]

        #expect(TodoQueries.untimed(todos, on: today, calendar: calendar).map(\.title) == ["All day"])
        #expect(TodoQueries.timed(todos, on: today, calendar: calendar).map(\.title) == ["Timed"])
    }

    /// Only the requested day's items are returned.
    @Test func calendarFiltersByDay() throws {
        let context = try makeContext()
        let today = calendar.startOfDay(for: Date())
        let todayTodo = Todo(title: "Today", assignedDate: today)
        let tomorrowTodo = Todo(title: "Tomorrow", assignedDate: day(offset: 1))
        [todayTodo, tomorrowTodo].forEach(context.insert)

        let todos = [todayTodo, tomorrowTodo]

        #expect(TodoQueries.scheduled(todos, on: today, calendar: calendar).map(\.title) == ["Today"])
    }

    // MARK: Spaces and projects

    @Test func spaceQueryExcludesProjectsAndSubtasks() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let loose = Todo(title: "Loose")
        let project = Todo(title: "Project", isProject: true)
        context.insert(space)
        [loose, project].forEach(context.insert)
        loose.move(toSpace: space)
        project.move(toSpace: space)

        let result = TodoQueries.inSpace([loose, project], spaceID: space.uuid)

        #expect(result.map(\.title) == ["Loose"])
    }

    @Test func projectQueryReturnsChildren() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        let child = Todo(title: "Child")
        [project, child].forEach(context.insert)
        project.addSubtask(child)

        #expect(TodoQueries.inProject([project, child], projectID: project.uuid).map(\.title) == ["Child"])
    }

    /// Projects with no space form the sidebar's ungrouped section.
    @Test func looseProjectsExcludeSpacedOnes() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let loose = Todo(title: "Loose", isProject: true)
        let filed = Todo(title: "Filed", isProject: true)
        context.insert(space)
        [loose, filed].forEach(context.insert)
        filed.move(toSpace: space)

        #expect(TodoQueries.looseProjects([loose, filed]).map(\.title) == ["Loose"])
    }

    // MARK: Ordering

    /// Dated work sorts ahead of undated work in cross-cutting lists.
    @Test func datedItemsSortBeforeUndated() throws {
        let context = try makeContext()
        let undated = Todo(title: "Undated")
        let dated = Todo(title: "Dated", assignedDate: day(offset: 0))
        [undated, dated].forEach(context.insert)
        undated.dueDate = day(offset: 0)

        let result = TodoQueries.anytime([dated, undated])
        #expect(result.first?.title == "Dated")
    }
}
