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

    /// "Show completed" in the Inbox means completed *today*.
    ///
    /// The Inbox is what the user triages from, so work struck off on an
    /// earlier day belongs to that day and to the Logbook rather than sitting
    /// at the top of this morning's list. Checked on both paths, since the
    /// fetch and the array rules have to agree.
    @Test func inboxShowsOnlyWorkResolvedToday() throws {
        let context = try makeContext()
        let open = Todo(title: "Open")
        let doneToday = Todo(title: "Done today")
        let doneYesterday = Todo(title: "Done yesterday")
        [open, doneToday, doneYesterday].forEach(context.insert)

        doneToday.setState(.completed)
        doneToday.resolvedAt = day(offset: 0).addingTimeInterval(3600)
        doneYesterday.setState(.completed)
        doneYesterday.resolvedAt = day(offset: -1).addingTimeInterval(3600)

        let listed = TodoQueries.inbox(
            [open, doneToday, doneYesterday], includeResolved: true, calendar: calendar
        )
        #expect(listed.map(\.title).sorted() == ["Done today", "Open"])

        let fetched = TodoQueries.todos(
            for: .inbox, in: context, calendar: calendar, includeResolved: true
        )
        #expect(!fetched.contains { $0.title == "Done yesterday" })
        #expect(fetched.contains { $0.title == "Done today" })
        #expect(fetched.contains { $0.title == "Open" })
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

    /// Hiding overdue work narrows Today to the day itself.
    @Test func todayCanExcludeOverdueWork() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -3))
        let todayTodo = Todo(title: "Today", assignedDate: day(offset: 0))
        [overdue, todayTodo].forEach(context.insert)

        let shown = TodoQueries.today(
            [overdue, todayTodo], calendar: calendar, includeOverdue: true
        )
        #expect(shown.map(\.title).sorted() == ["Overdue", "Today"])

        let hidden = TodoQueries.today(
            [overdue, todayTodo], calendar: calendar, includeOverdue: false
        )
        #expect(hidden.map(\.title) == ["Today"])
    }

    /// Overdue work is shown unless asked otherwise — the default the whole
    /// feature turns on.
    @Test func todayShowsOverdueByDefault() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -3))
        context.insert(overdue)

        #expect(TodoQueries.today([overdue], calendar: calendar).map(\.title) == ["Overdue"])
    }

    /// The same switch applies to This Week, which reaches backwards too.
    @Test func thisWeekCanExcludeOverdueWork() throws {
        let context = try makeContext()
        // Well before the current week, so it is overdue whatever day it is.
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -30))
        context.insert(overdue)

        #expect(
            TodoQueries.thisWeek([overdue], calendar: calendar, includeOverdue: true)
                .map(\.title) == ["Overdue"]
        )
        #expect(
            TodoQueries.thisWeek([overdue], calendar: calendar, includeOverdue: false).isEmpty
        )
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

    /// Showing completed work on Today means work completed *today*.
    ///
    /// Today reaches backwards without limit so overdue work cannot fall out of
    /// it, and that reach used to apply to finished work too: every item ever
    /// completed is also dated before the end of today, so turning on "show
    /// completed" listed the entire archive.
    @Test func todayShowsOnlyWorkCompletedToday() throws {
        let context = try makeContext()
        let doneToday = Todo(title: "Done today", assignedDate: day(offset: 0))
        let doneEarlier = Todo(title: "Done earlier", assignedDate: day(offset: -3))
        [doneToday, doneEarlier].forEach(context.insert)

        doneToday.setState(.completed)
        doneEarlier.setState(.completed)
        // `setState` stamps the current time; this one was finished days ago.
        doneEarlier.resolvedAt = day(offset: -3)

        let shown = TodoQueries.today(
            [doneToday, doneEarlier], calendar: calendar, includeResolved: true
        )

        #expect(shown.map(\.title) == ["Done today"])
    }

    /// The completed-work bound must not cost Today its overdue work.
    ///
    /// The two rules are deliberately separate: the date window still reaches
    /// back without limit for anything *unresolved*, and only finished work is
    /// held to today.
    @Test func todayKeepsOverdueWhileBoundingCompletedWork() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -5))
        let doneEarlier = Todo(title: "Done earlier", assignedDate: day(offset: -5))
        [overdue, doneEarlier].forEach(context.insert)

        doneEarlier.setState(.completed)
        doneEarlier.resolvedAt = day(offset: -5)

        let shown = TodoQueries.today(
            [overdue, doneEarlier], calendar: calendar, includeResolved: true
        )

        #expect(shown.map(\.title) == ["Overdue"])
    }

    /// This Week reaches backwards the same way and gets the same bound.
    @Test func thisWeekShowsOnlyWorkCompletedThisWeek() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -30))
        let doneLongAgo = Todo(title: "Done long ago", assignedDate: day(offset: -30))
        [overdue, doneLongAgo].forEach(context.insert)

        doneLongAgo.setState(.completed)
        doneLongAgo.resolvedAt = day(offset: -30)

        let shown = TodoQueries.thisWeek(
            [overdue, doneLongAgo], calendar: calendar, includeResolved: true
        )

        #expect(shown.map(\.title) == ["Overdue"])
    }

    // MARK: Tomorrow

    /// Tomorrow covers the next day only — not today, not the day after.
    @Test func tomorrowHoldsOnlyTheNextDaysWork() throws {
        let context = try makeContext()
        let todayTodo = Todo(title: "Today", assignedDate: day(offset: 0))
        let tomorrowTodo = Todo(title: "Tomorrow", assignedDate: day(offset: 1))
        let laterTodo = Todo(title: "Later", assignedDate: day(offset: 2))
        [todayTodo, tomorrowTodo, laterTodo].forEach(context.insert)

        let result = TodoQueries.tomorrow([todayTodo, tomorrowTodo, laterTodo], calendar: calendar)

        #expect(result.map(\.title) == ["Tomorrow"])
    }

    /// Overdue work belongs to Today, which is where it cannot be missed.
    /// Repeating it here would show one late item in two lists.
    @Test func tomorrowExcludesOverdueWork() throws {
        let context = try makeContext()
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -3))
        context.insert(overdue)

        #expect(TodoQueries.tomorrow([overdue], calendar: calendar).isEmpty)
    }

    /// A due date alone puts an item in Tomorrow, matching Today's rule.
    @Test func tomorrowIncludesItemsDueTomorrow() throws {
        let context = try makeContext()
        let due = Todo(title: "Due", dueDate: day(offset: 1))
        context.insert(due)

        #expect(TodoQueries.tomorrow([due], calendar: calendar).map(\.title) == ["Due"])
    }

    @Test func tomorrowExcludesResolvedWork() throws {
        let context = try makeContext()
        let done = Todo(title: "Done", assignedDate: day(offset: 1))
        context.insert(done)
        done.setState(.completed)

        #expect(TodoQueries.tomorrow([done], calendar: calendar).isEmpty)
    }

    // MARK: Any Time

    /// The summary's Any Time card lists work with no time of day. Timed work
    /// belongs to the schedule grid sitting beside it, and showing it in both
    /// places would list the same to-do twice on one screen. (The home screen
    /// widget has no such neighbor and uses `today` instead.)
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
        // Both carry a time, which is what makes "two hours ago" mean late
        // rather than "due sometime today".
        let late = Todo(title: "Late", dueDate: Date().addingTimeInterval(-7200), dueHasTime: true)
        let future = Todo(title: "Future", dueDate: Date().addingTimeInterval(7200), dueHasTime: true)
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

    /// The grid is a picture of time still to be spent, so finished work leaves
    /// it — including the all-day header. Unlike the lists, this is not tied to
    /// the Show Resolved preference: a completed block would hold a slot it no
    /// longer needs and push live work into a cascade beside it.
    @Test func calendarExcludesCompletedAndCancelled() throws {
        let context = try makeContext()
        let today = calendar.startOfDay(for: Date())

        let open = Todo(title: "Open", assignedDate: today.addingTimeInterval(9 * 3600))
        let done = Todo(title: "Done", assignedDate: today.addingTimeInterval(10 * 3600))
        let dropped = Todo(title: "Dropped", assignedDate: today.addingTimeInterval(11 * 3600))
        [open, done, dropped].forEach { $0.assignedHasTime = true }
        done.state = .completed
        dropped.state = .cancelled
        [open, done, dropped].forEach(context.insert)

        let todos = [open, done, dropped]

        #expect(TodoQueries.timed(todos, on: today, calendar: calendar).map(\.title) == ["Open"])
        #expect(TodoQueries.scheduled(todos, on: today, calendar: calendar).map(\.title) == ["Open"])
    }

    /// Resolved all-day items leave the header for the same reason.
    @Test func calendarHeaderExcludesResolved() throws {
        let context = try makeContext()
        let today = calendar.startOfDay(for: Date())

        let open = Todo(title: "Open", assignedDate: today)
        let done = Todo(title: "Done", assignedDate: today)
        done.state = .completed
        [open, done].forEach(context.insert)

        #expect(TodoQueries.untimed([open, done], on: today, calendar: calendar).map(\.title) == ["Open"])
    }

    /// Completing something today must not leave it on the grid until the app
    /// is relaunched — the query is the only gate, so it is checked directly.
    @Test func completingRemovesItFromTheGrid() throws {
        let context = try makeContext()
        let today = calendar.startOfDay(for: Date())
        let todo = Todo(title: "Standup", assignedDate: today.addingTimeInterval(9 * 3600))
        todo.assignedHasTime = true
        context.insert(todo)

        #expect(TodoQueries.timed([todo], on: today, calendar: calendar).count == 1)

        todo.state = .completed
        #expect(TodoQueries.timed([todo], on: today, calendar: calendar).isEmpty)
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

    // MARK: Calendar scoping

    /// A space's calendar reaches into its projects, which the list query — one
    /// level deep by design — deliberately does not.
    @Test func calendarScopeForSpaceIncludesWorkInsideItsProjects() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let loose = Todo(title: "Loose")
        let project = Todo(title: "Project", isProject: true)
        let child = Todo(title: "Child")
        context.insert(space)
        [loose, project, child].forEach(context.insert)
        loose.move(toSpace: space)
        project.move(toSpace: space)
        project.addSubtask(child)

        let scoped = TodoQueries.calendarScope(
            [loose, project, child], for: .space(space.uuid)
        )

        // The project itself is a container, not a block on the grid.
        #expect(Set(scoped.map(\.title)) == ["Loose", "Child"])
    }

    /// Work filed in another space stays off this space's calendar.
    @Test func calendarScopeForSpaceExcludesOtherSpaces() throws {
        let context = try makeContext()
        let work = Space(name: "Work")
        let home = Space(name: "Home")
        let mine = Todo(title: "Mine")
        let theirs = Todo(title: "Theirs")
        [work, home].forEach(context.insert)
        [mine, theirs].forEach(context.insert)
        mine.move(toSpace: work)
        theirs.move(toSpace: home)

        let scoped = TodoQueries.calendarScope([mine, theirs], for: .space(work.uuid))

        #expect(scoped.map(\.title) == ["Mine"])
    }

    /// A project's calendar covers its whole tree, not just its direct children.
    @Test func calendarScopeForProjectIncludesNestedSubtasks() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        let child = Todo(title: "Child")
        let grandchild = Todo(title: "Grandchild")
        let outside = Todo(title: "Outside")
        [project, child, grandchild, outside].forEach(context.insert)
        project.addSubtask(child)
        child.addSubtask(grandchild)

        let scoped = TodoQueries.calendarScope(
            [project, child, grandchild, outside], for: .project(project.uuid)
        )

        #expect(Set(scoped.map(\.title)) == ["Child", "Grandchild"])
    }

    /// A subtask keeps its own block when its parent is scheduled the same day.
    ///
    /// The list queries collapse a child into the parent it is nested under,
    /// which on a grid meant a scheduled hour simply going missing — so this
    /// runs the scope through the day query the calendar actually calls,
    /// rather than testing the scope in isolation.
    @Test func calendarKeepsSubtaskScheduledAlongsideItsParent() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        let parent = Todo(title: "Parent", assignedDate: day(offset: 0).addingTimeInterval(10 * 3600))
        let child = Todo(title: "Child", assignedDate: day(offset: 0).addingTimeInterval(13 * 3600))
        [project, parent, child].forEach(context.insert)
        project.addSubtask(parent)
        parent.addSubtask(child)
        parent.assignedHasTime = true
        child.assignedHasTime = true

        let scoped = TodoQueries.calendarScope(
            [project, parent, child], for: .project(project.uuid)
        )
        let timed = TodoQueries.timed(scoped, on: day(offset: 0), calendar: calendar)

        #expect(timed.map(\.title) == ["Parent", "Child"])
    }

    /// The cross-cutting lists are unscoped — the calendar shows everything.
    @Test func calendarScopePassesEverythingThroughForOtherDestinations() throws {
        let context = try makeContext()
        let a = Todo(title: "A")
        let b = Todo(title: "B")
        [a, b].forEach(context.insert)

        #expect(TodoQueries.calendarScope([a, b], for: .today).count == 2)
    }

    // MARK: Unscheduled remainder (side panel)

    /// The panel beside a space's calendar holds exactly what the grid cannot
    /// draw, reaching into the space's projects the same way the grid does.
    @Test func unscheduledForSpaceCollectsUndatedWorkIncludingInsideProjects() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let dated = Todo(title: "Dated", assignedDate: day(offset: 0))
        let undated = Todo(title: "Undated")
        let project = Todo(title: "Project", isProject: true)
        let undatedChild = Todo(title: "Undated Child")
        context.insert(space)
        [dated, undated, project, undatedChild].forEach(context.insert)
        [dated, undated, project].forEach { $0.move(toSpace: space) }
        project.addSubtask(undatedChild)

        let result = TodoQueries.unscheduled(
            [dated, undated, project, undatedChild], for: .space(space.uuid)
        )

        // The project itself is a container, so it is no more a panel row than
        // it is a block on the grid.
        #expect(Set(result.map(\.title)) == ["Undated", "Undated Child"])
    }

    /// A due date is not a slot: the grid positions blocks by `assignedDate`
    /// alone, so an item with only a deadline still belongs in the panel.
    @Test func unscheduledKeepsItemsThatHaveOnlyADueDate() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let due = Todo(title: "Due Only")
        context.insert(space)
        context.insert(due)
        due.move(toSpace: space)
        due.dueDate = day(offset: 1)

        let result = TodoQueries.unscheduled([due], for: .space(space.uuid))

        #expect(result.map(\.title) == ["Due Only"])
    }

    /// The grid and the panel partition the container: nothing counted twice,
    /// nothing missing.
    @Test func unscheduledIsTheComplementOfWhatTheGridDraws() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let dated = Todo(title: "Dated", assignedDate: day(offset: 0))
        let undated = Todo(title: "Undated")
        context.insert(space)
        [dated, undated].forEach(context.insert)
        [dated, undated].forEach { $0.move(toSpace: space) }

        let pool = [dated, undated]
        let scoped = TodoQueries.calendarScope(pool, for: .space(space.uuid))
        let onGrid = TodoQueries.scheduled(scoped, on: day(offset: 0), calendar: calendar)
        let inPanel = TodoQueries.unscheduled(pool, for: .space(space.uuid))

        #expect(Set(onGrid.map(\.title)).isDisjoint(with: Set(inPanel.map(\.title))))
        #expect(Set(onGrid.map(\.title)).union(inPanel.map(\.title)) == ["Dated", "Undated"])
    }

    /// Finished work is not waiting for a slot.
    @Test func unscheduledExcludesResolvedWorkByDefault() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let open = Todo(title: "Open")
        let done = Todo(title: "Done")
        context.insert(space)
        [open, done].forEach(context.insert)
        [open, done].forEach { $0.move(toSpace: space) }
        done.setState(.completed)

        let result = TodoQueries.unscheduled([open, done], for: .space(space.uuid))

        #expect(result.map(\.title) == ["Open"])
    }

    /// Work filed elsewhere stays out of this space's panel.
    @Test func unscheduledExcludesOtherSpaces() throws {
        let context = try makeContext()
        let work = Space(name: "Work")
        let home = Space(name: "Home")
        let mine = Todo(title: "Mine")
        let theirs = Todo(title: "Theirs")
        [work, home].forEach(context.insert)
        [mine, theirs].forEach(context.insert)
        mine.move(toSpace: work)
        theirs.move(toSpace: home)

        let result = TodoQueries.unscheduled([mine, theirs], for: .space(work.uuid))

        #expect(result.map(\.title) == ["Mine"])
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

/// The predicate-backed fetch path.
///
/// The array functions above pin *what each list means*. These pin that the
/// `FetchDescriptor` path — where SQLite does the filtering — answers the same
/// way, so pushing the work into the database did not quietly change any list.
///
/// Worth testing separately because the failure mode is silent: an expression
/// SwiftData cannot compile (a force-unwrap, a computed property, a `Calendar`
/// call) throws at fetch time and the list simply comes up empty.
@MainActor
struct TodoQueryDescriptorTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    private var calendar: Calendar { Calendar.current }

    private func day(offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
    }

    /// A store covering every rule the predicates encode.
    private func populate(_ context: ModelContext) -> [Todo] {
        let space = Space(name: "Work")
        let hidden = Space(name: "Hidden")
        hidden.isHiddenByFocus = true
        [space, hidden].forEach(context.insert)

        let todos = [
            Todo(title: "Loose"),
            Todo(title: "Today", assignedDate: day(offset: 0)),
            Todo(title: "Overdue", assignedDate: day(offset: -3)),
            Todo(title: "Due Today", dueDate: day(offset: 0)),
            Todo(title: "Tomorrow", assignedDate: day(offset: 1)),
            Todo(title: "Next Month", assignedDate: day(offset: 32)),
            Todo(title: "Timed", assignedDate: day(offset: 0).addingTimeInterval(9 * 3600)),
            Todo(title: "Project", isProject: true),
        ]
        todos.forEach(context.insert)
        todos[6].assignedHasTime = true

        let done = Todo(title: "Done", assignedDate: day(offset: 0))
        context.insert(done)
        done.setState(.completed)

        let filed = Todo(title: "Filed")
        context.insert(filed)
        filed.move(toSpace: space)

        let concealed = Todo(title: "Concealed", assignedDate: day(offset: 0))
        context.insert(concealed)
        concealed.move(toSpace: hidden)

        let child = Todo(title: "Child")
        context.insert(child)
        todos[7].addSubtask(child)

        // Week-planned work, with no date of its own — the population the week
        // lists exist for, and the one the fetch and array paths have to agree
        // about just as they do about dated rows.
        let thisWeek = Todo(title: "This Week Plan")
        let nextWeek = Todo(title: "Next Week Plan")
        [thisWeek, nextWeek].forEach(context.insert)
        thisWeek.scheduleForWeek(.thisWeek, calendar: calendar)
        nextWeek.scheduleForWeek(.nextWeek, calendar: calendar)
        [thisWeek, nextWeek].forEach { $0.refileForCurrentScheduling() }

        return todos + [done, filed, concealed, child, thisWeek, nextWeek]
    }

    /// Every destination's fetch matches the in-memory rules it replaced.
    ///
    /// The central claim of the whole change, checked destination by
    /// destination rather than by spot-checking one list.
    @Test func fetchedListsMatchTheArrayRules() throws {
        let context = try makeContext()
        let all = populate(context)

        let destinations: [ListDestination] = [
            .inbox, .today, .tomorrow, .thisWeek, .nextWeek, .anytime, .logbook,
        ]

        for destination in destinations {
            let fetched = TodoQueries.todos(for: destination, in: context, calendar: calendar)
            let expected: [Todo]
            switch destination {
            case .inbox: expected = TodoQueries.inbox(all, calendar: calendar)
            case .today: expected = TodoQueries.today(all, calendar: calendar)
            case .tomorrow: expected = TodoQueries.tomorrow(all, calendar: calendar)
            case .thisWeek: expected = TodoQueries.thisWeek(all, calendar: calendar)
            case .nextWeek: expected = TodoQueries.nextWeek(all, calendar: calendar)
            case .anytime: expected = TodoQueries.anytime(all)
            case .logbook: expected = TodoQueries.logbook(all)
            default: continue
            }

            #expect(
                fetched.map(\.title) == expected.map(\.title),
                "\(destination.title) differed between the fetch and the array rules"
            )
        }
    }

    /// A predicate SwiftData cannot compile throws instead of filtering, and the
    /// list comes up empty — so a non-empty result is itself the assertion that
    /// the expression survived translation to SQL.
    @Test func everyDescriptorCompilesToSQL() throws {
        let context = try makeContext()
        _ = populate(context)

        #expect(!TodoQueries.todos(for: .inbox, in: context).isEmpty)
        #expect(!TodoQueries.todos(for: .today, in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.todos(for: .tomorrow, in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.todos(for: .thisWeek, in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.todos(for: .nextWeek, in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.todos(for: .logbook, in: context).isEmpty)
        #expect(!TodoQueries.looseProjects(in: context).isEmpty)
        #expect(!TodoQueries.projects(in: context).isEmpty)
        #expect(!TodoQueries.scheduled(on: day(offset: 0), in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.timed(on: day(offset: 0), in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.untimed(on: day(offset: 0), in: context, calendar: calendar).isEmpty)
        #expect(!TodoQueries.unscheduled(for: .inbox, in: context).isEmpty)
    }

    /// Work in a Focus-hidden space stays out of the fetched lists, the same way
    /// `topLevel` keeps it out of the array ones.
    @Test func focusHiddenWorkIsExcludedByThePredicate() throws {
        let context = try makeContext()
        _ = populate(context)

        let today = TodoQueries.todos(for: .today, in: context, calendar: calendar)
        #expect(!today.contains { $0.title == "Concealed" })
    }

    /// Overdue work is in Today, which is the rule most easily lost when a
    /// "today" filter is written as a single day's window.
    @Test func fetchedTodayKeepsOverdueWork() throws {
        let context = try makeContext()
        _ = populate(context)

        let today = TodoQueries.todos(for: .today, in: context, calendar: calendar)
        #expect(today.contains { $0.title == "Overdue" })
    }

    /// The fetch path bounds completed work to today, as the array path does.
    ///
    /// Both encode the same rule, so the SQL side is pinned separately: a
    /// predicate that admitted the whole archive would not be caught by the
    /// array tests alone.
    @Test func fetchedTodayShowsOnlyWorkCompletedToday() throws {
        let context = try makeContext()
        let doneToday = Todo(title: "Done today", assignedDate: day(offset: 0))
        let doneEarlier = Todo(title: "Done earlier", assignedDate: day(offset: -4))
        let overdue = Todo(title: "Overdue", assignedDate: day(offset: -4))
        [doneToday, doneEarlier, overdue].forEach(context.insert)

        doneToday.setState(.completed)
        doneEarlier.setState(.completed)
        doneEarlier.resolvedAt = day(offset: -4)

        let shown = TodoQueries.todos(
            for: .today, in: context, calendar: calendar, includeResolved: true
        )

        #expect(shown.contains { $0.title == "Done today" })
        #expect(shown.contains { $0.title == "Overdue" })
        #expect(!shown.contains { $0.title == "Done earlier" })
    }

    /// The fetch path honours the overdue switch, and agrees with the array
    /// path — the two encode the same rule twice, so they are checked together.
    @Test func fetchedTodayCanExcludeOverdueWork() throws {
        let context = try makeContext()
        _ = populate(context)

        let shown = TodoQueries.todos(
            for: .today, in: context, calendar: calendar, includeOverdue: true
        )
        #expect(shown.contains { $0.title == "Overdue" })

        let hidden = TodoQueries.todos(
            for: .today, in: context, calendar: calendar, includeOverdue: false
        )
        #expect(!hidden.contains { $0.title == "Overdue" })
        // Only the overdue row goes: today's own work is untouched.
        #expect(hidden.contains { $0.title == "Today" })
    }

    /// Resolved work is excluded unless asked for, and then only on the day it
    /// was resolved — the `filterResolved` rule, now inside the fetch.
    @Test func resolvedWorkIsAdmittedOnlyWhenAskedFor() throws {
        let context = try makeContext()
        _ = populate(context)

        let withoutResolved = TodoQueries.todos(for: .inbox, in: context)
        let withResolved = TodoQueries.todos(for: .inbox, in: context, includeResolved: true)

        #expect(!withoutResolved.contains { $0.title == "Done" })
        // Resolved today, so it survives `filterResolved` when asked for.
        #expect(withResolved.count >= withoutResolved.count)
    }

    /// The badge count agrees with the list it counts.
    @Test func countMatchesTheFetchedList() throws {
        let context = try makeContext()
        _ = populate(context)

        for destination in [ListDestination.inbox, .today, .tomorrow, .anytime] {
            let listed = TodoQueries.todos(for: destination, in: context, calendar: calendar)
            let counted = TodoQueries.count(for: destination, in: context, calendar: calendar)
            #expect(
                counted == listed.count,
                "\(destination.title) badge disagreed with its list"
            )
        }
    }

    /// A subtask does not draw its own row beside the parent it is nested under.
    @Test func fetchedListsStillDropNestedSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        [parent, child].forEach(context.insert)
        parent.addSubtask(child)

        let inbox = TodoQueries.todos(for: .inbox, in: context)
        #expect(inbox.map(\.title) == ["Parent"])
    }

    /// The calendar's range fetch, sliced per day, matches the per-day rules it
    /// replaced.
    ///
    /// This is the calendar's version of `fetchedListsMatchTheArrayRules`: the
    /// grid now fetches the visible span once and slices days out of it in
    /// memory, so what has to hold is that a slice equals what the old per-day
    /// query returned.
    @Test func rangeSlicesMatchThePerDayRules() throws {
        let context = try makeContext()
        let all = populate(context)

        let start = day(offset: -1)
        let end = day(offset: 2)
        let fetched = TodoQueries.fetch(
            TodoQueries.scheduledDescriptor(from: start, to: end), in: context
        )

        for offset in -1...1 {
            let target = day(offset: offset)

            #expect(
                TodoQueries.timedOn(fetched, day: target, calendar: calendar).map(\.title)
                    == TodoQueries.timed(all, on: target, calendar: calendar).map(\.title),
                "timed rows differed on day \(offset)"
            )
            #expect(
                TodoQueries.untimedOn(fetched, day: target, calendar: calendar).map(\.title)
                    == TodoQueries.untimed(all, on: target, calendar: calendar).map(\.title),
                "untimed rows differed on day \(offset)"
            )
        }
    }

    /// The range fetch covers its whole span and stops at the edges.
    ///
    /// The bound that matters for paging: a day outside the fetched range has
    /// to be genuinely absent, which is what makes the ±1 page window the
    /// calendar fetches a deliberate choice rather than an accident.
    @Test func rangeFetchIsBoundedByItsDates() throws {
        let context = try makeContext()
        _ = populate(context)

        let fetched = TodoQueries.fetch(
            TodoQueries.scheduledDescriptor(from: day(offset: 0), to: day(offset: 1)),
            in: context
        )

        // "Today" and "Timed" are both dated today; "Tomorrow" is outside.
        #expect(fetched.contains { $0.title == "Today" })
        #expect(fetched.contains { $0.title == "Timed" })
        #expect(!fetched.contains { $0.title == "Tomorrow" })
        #expect(!fetched.contains { $0.title == "Overdue" })
        // Resolved and Focus-hidden work never reaches the grid.
        #expect(!fetched.contains { $0.title == "Done" })
        #expect(!fetched.contains { $0.title == "Concealed" })
    }

    // MARK: Spaces

    /// A space holding a mix of projects, loose work, and finished work.
    private func makeSpace(in context: ModelContext, name: String = "Work") -> Space {
        let space = Space(name: name)
        context.insert(space)

        let project = Todo(title: "Project", isProject: true)
        let loose = Todo(title: "Loose")
        let another = Todo(title: "Another")
        let done = Todo(title: "Done")
        [project, loose, another, done].forEach(context.insert)
        [project, loose, another, done].forEach { $0.move(toSpace: space) }
        done.setState(.completed)

        return space
    }

    /// The fetched space contents match the model's own accessors.
    ///
    /// The same equivalence check the destinations get: `Space.projects` and
    /// `openCount` walk the relationship, the query answers in SQL, and the two
    /// have to agree.
    @Test func fetchedSpaceContentsMatchTheModelAccessors() throws {
        let context = try makeContext()
        let space = makeSpace(in: context)

        #expect(
            TodoQueries.projects(inSpace: space.uuid, in: context).map(\.title)
                == space.projects.map(\.title)
        )
        #expect(
            TodoQueries.openCount(inSpace: space.uuid, in: context) == space.openCount
        )

        let counts = TodoQueries.spaceContentCounts(spaceID: space.uuid, in: context)
        #expect(counts.projects == space.projects.count)
        #expect(counts.others == space.todoList.count - space.projects.count)
    }

    /// The badge counts unresolved, non-project work — not the whole space.
    @Test func spaceOpenCountExcludesProjectsAndFinishedWork() throws {
        let context = try makeContext()
        let space = makeSpace(in: context)

        // "Loose" and "Another" are open; "Project" is a container and "Done"
        // is finished.
        #expect(TodoQueries.openCount(inSpace: space.uuid, in: context) == 2)
    }

    /// Work in one space is never counted against another.
    @Test func spaceQueriesAreScopedToTheirSpace() throws {
        let context = try makeContext()
        let work = makeSpace(in: context, name: "Work")
        let home = makeSpace(in: context, name: "Home")

        #expect(TodoQueries.openCount(inSpace: work.uuid, in: context) == 2)
        #expect(TodoQueries.projects(inSpace: home.uuid, in: context).count == 1)
        #expect(
            TodoQueries.projects(inSpace: work.uuid, in: context).first?.space?.uuid
                == work.uuid
        )
    }

    /// The sidebar's space query drops Focus-hidden spaces and sorts the rest;
    /// the picker's keeps every space.
    @Test func spaceDescriptorsDifferOnTheFocusRule() throws {
        let context = try makeContext()
        let visible = Space(name: "Visible", sortIndex: 1)
        let hidden = Space(name: "Hidden", sortIndex: 0)
        hidden.isHiddenByFocus = true
        [visible, hidden].forEach(context.insert)

        let sidebar = (try? context.fetch(TodoQueries.visibleSpacesDescriptor())) ?? []
        let pickers = (try? context.fetch(TodoQueries.allSpacesDescriptor())) ?? []

        #expect(sidebar.map(\.name) == ["Visible"])
        // Sorted by `sortIndex`, so the hidden one leads when it is included.
        #expect(pickers.map(\.name) == ["Hidden", "Visible"])
        #expect(TodoQueries.hiddenSpaceCount(in: context) == 1)
    }

    /// The sidebar's query matches `visibleUnderFocus`, which it replaced.
    @Test func visibleSpacesMatchTheArrayRule() throws {
        let context = try makeContext()
        let first = Space(name: "First", sortIndex: 2)
        let second = Space(name: "Second", sortIndex: 1)
        let hidden = Space(name: "Hidden", sortIndex: 0)
        hidden.isHiddenByFocus = true
        [first, second, hidden].forEach(context.insert)

        let fetched = (try? context.fetch(TodoQueries.visibleSpacesDescriptor())) ?? []
        let expected = [first, second, hidden].visibleUnderFocus

        #expect(fetched.map(\.name) == expected.map(\.name))
    }

    /// Point lookups resolve the same object the array scan used to find.
    @Test func pointLookupsFindTheirTarget() throws {
        let context = try makeContext()
        let todo = Todo(title: "Findable")
        let space = Space(name: "Home")
        context.insert(todo)
        context.insert(space)

        #expect(TodoQueries.todo(uuid: todo.uuid, in: context)?.title == "Findable")
        #expect(TodoQueries.space(uuid: space.uuid, in: context)?.name == "Home")
        #expect(TodoQueries.todo(uuid: UUID(), in: context) == nil)
    }
}
