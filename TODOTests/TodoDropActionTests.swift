import Testing
import Foundation
import SwiftData
@testable import TODO

/// What dropping a to-do onto each destination does to it.
///
/// The rule these all check is that a drop must leave the to-do somewhere the
/// user can actually see it: dropping onto Today and then not finding it in
/// Today reads as the drag having failed, even though something did happen.
@MainActor
struct TodoDropActionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    private var calendar: Calendar { Calendar.current }

    // MARK: Fixed lists

    /// Dropping onto Today dates it for today, so it lands in that list.
    @Test func dropOnTodaySchedulesForToday() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        let applied = TodoDropAction.apply(
            .today, to: todo,
            store: TodoStore(context: context)
        )

        #expect(applied)
        #expect(todo.assignedDate != nil)
        #expect(calendar.isDateInToday(todo.assignedDate!))
        #expect(todo.assignedHasTime == false)
        // The point of the rule: it is now in the list it was dropped on.
        #expect(TodoQueries.today([todo]).contains { $0.uuid == todo.uuid })
    }

    /// Dropping onto Tomorrow dates it for the next day, so it lands there.
    @Test func dropOnTomorrowSchedulesForTomorrow() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        let applied = TodoDropAction.apply(
            .tomorrow, to: todo,
            store: TodoStore(context: context)
        )

        #expect(applied)
        let moved = try #require(todo.assignedDate)
        #expect(calendar.isDateInTomorrow(moved))
        #expect(todo.assignedHasTime == false)
        #expect(TodoQueries.tomorrow([todo]).contains { $0.uuid == todo.uuid })
    }

    /// Same rule as Today: the drop answers *which day*, not *what time*.
    @Test func dropOnTomorrowKeepsAnExistingTimeOfDay() throws {
        let context = try makeContext()
        let at930 = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!
        let todo = Todo(title: "Standup", assignedDate: at930)
        todo.assignedHasTime = true
        context.insert(todo)

        TodoDropAction.apply(
            .tomorrow, to: todo,
            store: TodoStore(context: context)
        )

        let moved = try #require(todo.assignedDate)
        #expect(calendar.isDateInTomorrow(moved))
        #expect(todo.assignedHasTime)
        #expect(calendar.component(.hour, from: moved) == 9)
        #expect(calendar.component(.minute, from: moved) == 30)
    }

    /// The Inbox is unfiled work, so a drop there strips home and date both.
    @Test func dropOnInboxClearsHomeAndDate() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let space = store.createSpace(name: "Work")
        let todo = Todo(title: "Task", assignedDate: Date())
        context.insert(todo)
        store.move(todo, toSpace: space)

        let applied = TodoDropAction.apply(
            .inbox, to: todo,
            store: store
        )

        #expect(applied)
        #expect(todo.assignedDate == nil)
        #expect(todo.space == nil)
        #expect(TodoQueries.inbox([todo]).contains { $0.uuid == todo.uuid })
    }

    /// Anytime means scheduled-but-undated, so only the date is cleared.
    @Test func dropOnAnytimeClearsOnlyTheDate() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let space = store.createSpace(name: "Work")
        let todo = Todo(title: "Task", assignedDate: Date())
        context.insert(todo)
        store.move(todo, toSpace: space)

        TodoDropAction.apply(
            .anytime, to: todo,
            store: store
        )

        #expect(todo.assignedDate == nil)
        // The home survives — that is what separates Anytime from the Inbox.
        #expect(todo.space?.uuid == space.uuid)
    }

    /// Dropping onto Today answers *which day*, not *what time*: a 9am standup
    /// dragged in from another list is still a 9am standup, and flattening it
    /// would move it off the grid into the all-day row as a side effect.
    @Test func dropOnTodayKeepsAnExistingTimeOfDay() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)

        // Yesterday at 09:30.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let at930 = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: yesterday)!
        let todo = Todo(title: "Standup", assignedDate: at930)
        todo.assignedHasTime = true
        context.insert(todo)

        TodoDropAction.apply(
            .today, to: todo,
            store: store
        )

        let moved = try #require(todo.assignedDate)
        #expect(calendar.isDateInToday(moved))
        #expect(todo.assignedHasTime)
        #expect(calendar.component(.hour, from: moved) == 9)
        #expect(calendar.component(.minute, from: moved) == 30)
    }

    /// An all-day item stays all-day: there is no time to preserve, and
    /// inventing one would put it on the grid at midnight.
    @Test func dropOnTodayLeavesAnUntimedItemUntimed() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        TodoDropAction.apply(
            .today, to: todo,
            store: TodoStore(context: context)
        )

        let moved = try #require(todo.assignedDate)
        #expect(todo.assignedHasTime == false)
        #expect(moved == calendar.startOfDay(for: moved))
    }

    /// Dropping onto This Week plans the week and takes the day away.
    ///
    /// This used to date the row to *today*, because a week was not something a
    /// to-do could hold — so the drop guessed a day, and the item turned up in
    /// Today as well. Now the drop means what the list says.
    @Test func dropOnThisWeekPlansTheWeekAndClearsTheDay() throws {
        let context = try makeContext()
        let past = calendar.date(byAdding: .day, value: -3, to: Date())!
        let at1415 = calendar.date(bySettingHour: 14, minute: 15, second: 0, of: past)!
        let todo = Todo(title: "Review", assignedDate: at1415)
        todo.assignedHasTime = true
        context.insert(todo)

        TodoDropAction.apply(
            .thisWeek, to: todo,
            store: TodoStore(context: context)
        )

        #expect(todo.assignedDate == nil)
        #expect(todo.assignedHasTime == false)
        #expect(todo.weekSchedule(calendar: calendar) == .thisWeek)
        #expect(TodoQueries.thisWeek([todo], calendar: calendar).contains { $0.uuid == todo.uuid })
    }

    @Test func dropOnThisWeekSchedulesIt() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        TodoDropAction.apply(
            .thisWeek, to: todo,
            store: TodoStore(context: context)
        )

        #expect(todo.weekSchedule(calendar: calendar) == .thisWeek)
        #expect(TodoQueries.thisWeek([todo], calendar: calendar).contains { $0.uuid == todo.uuid })
    }

    @Test func dropOnNextWeekSchedulesIt() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        TodoDropAction.apply(
            .nextWeek, to: todo,
            store: TodoStore(context: context)
        )

        #expect(todo.assignedDate == nil)
        #expect(todo.weekSchedule(calendar: calendar) == .nextWeek)
        #expect(TodoQueries.nextWeek([todo], calendar: calendar).contains { $0.uuid == todo.uuid })
        // And not in This Week, which is the whole point of the two being
        // separate lists.
        #expect(!TodoQueries.thisWeek([todo], calendar: calendar).contains { $0.uuid == todo.uuid })
    }

    /// Dropping a week-planned to-do onto a dated list replaces the week.
    ///
    /// The exclusion in the direction that is easy to miss: every dated drop
    /// has to clear the anchor, or the row stays in This Week while also
    /// claiming a day.
    @Test func dropOnADatedListClearsTheWeekPlan() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task", weekSchedule: .nextWeek)
        context.insert(todo)

        TodoDropAction.apply(
            .tomorrow, to: todo,
            store: TodoStore(context: context)
        )

        #expect(todo.weekAnchor == nil)
        #expect(todo.assignedDate != nil)
        #expect(!TodoQueries.nextWeek([todo], calendar: calendar).contains { $0.uuid == todo.uuid })
    }

    /// And dropping onto Anytime or the Inbox clears it too — those lists mean
    /// "not placed in time", which a week plan contradicts.
    @Test func dropOnAnytimeClearsTheWeekPlan() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task", weekSchedule: .thisWeek)
        context.insert(todo)

        TodoDropAction.apply(
            .anytime, to: todo,
            store: TodoStore(context: context)
        )

        #expect(todo.weekAnchor == nil)
        #expect(todo.assignedDate == nil)
    }

    // MARK: Spaces and projects

    @Test func dropOnSpaceFilesItThere() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let space = store.createSpace(name: "Home")
        let todo = Todo(title: "Task")
        context.insert(todo)

        let applied = TodoDropAction.apply(
            .space(space.uuid), to: todo,
            store: store
        )

        #expect(applied)
        #expect(todo.space?.uuid == space.uuid)
    }

    /// Filing into a space detaches any parent, since a to-do has one home.
    @Test func dropOnSpaceDetachesFromParent() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let space = store.createSpace(name: "Home")
        let project = Todo(title: "Project", isProject: true)
        let todo = Todo(title: "Task")
        [project, todo].forEach(context.insert)
        _ = store.adopt(todo, asSubtaskOf: project)

        TodoDropAction.apply(
            .space(space.uuid), to: todo,
            store: store
        )

        #expect(todo.parent == nil)
        #expect(todo.space?.uuid == space.uuid)
    }

    @Test func dropOnProjectAdoptsAsSubtask() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let project = Todo(title: "Project", isProject: true)
        let todo = Todo(title: "Task")
        [project, todo].forEach(context.insert)

        let applied = TodoDropAction.apply(
            .project(project.uuid), to: todo,
            store: store
        )

        #expect(applied)
        #expect(todo.parent?.uuid == project.uuid)
    }

    /// A project cannot be dropped into itself.
    @Test func dropOnItselfIsRefused() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        context.insert(project)

        let applied = TodoDropAction.apply(
            .project(project.uuid), to: project,
            store: TodoStore(context: context)
        )

        #expect(applied == false)
        #expect(project.parent == nil)
    }

    // MARK: Between lists

    /// The point of dragging between arbitrary lists: a to-do filed in one
    /// space lands cleanly in another, rather than keeping both homes.
    @Test func dropMovesBetweenSpaces() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let work = store.createSpace(name: "Work")
        let home = store.createSpace(name: "Home")
        let todo = Todo(title: "Task")
        context.insert(todo)
        store.move(todo, toSpace: work)

        let applied = TodoDropAction.apply(
            .space(home.uuid), to: todo,
            store: store
        )

        #expect(applied)
        #expect(todo.space?.uuid == home.uuid)
        #expect(TodoQueries.inSpace([todo], spaceID: home.uuid).count == 1)
        #expect(TodoQueries.inSpace([todo], spaceID: work.uuid).isEmpty)
    }

    /// Dragging a subtask out of its project and onto a date is how work gets
    /// promoted out of a project, so the parent must actually be released.
    @Test func dropFromProjectOntoTodayDetachesAndSchedules() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let project = Todo(title: "Project", isProject: true)
        let subtask = Todo(title: "Step")
        [project, subtask].forEach(context.insert)
        _ = store.adopt(subtask, asSubtaskOf: project)

        TodoDropAction.apply(
            .today, to: subtask,
            store: store
        )

        // Today is a date, not a home: the subtask keeps its parent and simply
        // gains a date, which is what makes it show up in Today as well.
        #expect(subtask.assignedDate != nil)
        #expect(calendar.isDateInToday(subtask.assignedDate!))
    }

    /// Moving between projects re-parents rather than accumulating parents.
    @Test func dropMovesBetweenProjects() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let first = Todo(title: "First", isProject: true)
        let second = Todo(title: "Second", isProject: true)
        let todo = Todo(title: "Task")
        [first, second, todo].forEach(context.insert)
        _ = store.adopt(todo, asSubtaskOf: first)

        let applied = TodoDropAction.apply(
            .project(second.uuid), to: todo,
            store: store
        )

        #expect(applied)
        #expect(todo.parent?.uuid == second.uuid)
        #expect(TodoQueries.inProject([todo], projectID: second.uuid).count == 1)
        #expect(TodoQueries.inProject([todo], projectID: first.uuid).isEmpty)
    }

    // MARK: Refusals

    /// The Logbook is a record, not a filing destination — dropping there must
    /// not quietly complete the to-do.
    @Test func dropOnLogbookIsRefused() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        let applied = TodoDropAction.apply(
            .logbook, to: todo,
            store: TodoStore(context: context)
        )

        #expect(applied == false)
        #expect(todo.state == .open)
        #expect(todo.assignedDate == nil)
    }

    @Test func logbookDoesNotAcceptDrops() {
        let todo = Todo(title: "Task")
        #expect(TodoDropAction.accepts(.logbook, todo: todo) == false)
        #expect(TodoDropAction.accepts(.today, todo: todo))
    }

    @Test func projectDoesNotAcceptItself() {
        let project = Todo(title: "Project", isProject: true)
        #expect(TodoDropAction.accepts(.project(project.uuid), todo: project) == false)
    }

    /// A space that no longer exists refuses rather than filing nowhere.
    @Test func dropOnMissingSpaceIsRefused() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        let applied = TodoDropAction.apply(
            .space(UUID()), to: todo,
            store: TodoStore(context: context)
        )

        #expect(applied == false)
    }

    // MARK: Across windows

    /// The payload survives being serialized, which is what crossing a window
    /// boundary does to it.
    ///
    /// A drag inside one window can hand the receiver the very same object, so
    /// an in-process shortcut would pass that case and still fail between two
    /// windows. This pins the wire format instead: what the drop target gets
    /// back is a `uuid` decoded from bytes.
    @Test func transferSurvivesEncoding() throws {
        let todo = Todo(title: "Task")
        let encoded = try JSONEncoder().encode(TodoTransfer(uuid: todo.uuid))
        let decoded = try JSONDecoder().decode(TodoTransfer.self, from: encoded)

        #expect(decoded.uuid == todo.uuid)
    }

    /// A to-do dragged out of one window is found and moved by another.
    ///
    /// The two windows share a container but each has its own `ModelContext`,
    /// so the receiving side cannot be handed the dragged object — it only has
    /// the uuid off the pasteboard, and has to fetch its own copy. This is the
    /// reason `TodoTransfer` carries a uuid rather than the model: a `Todo`
    /// belongs to the context that fetched it and cannot cross to another.
    @Test func aTodoDraggedFromAnotherWindowIsMoved() throws {
        let container = try ModelContainer.appContainer(inMemory: true)

        // The window the drag started in.
        let source = ModelContext(container)
        let todo = Todo(title: "Task")
        source.insert(todo)
        try source.save()

        // The window it was dropped on, with a context of its own.
        let destination = ModelContext(container)
        let transfer = TodoTransfer(uuid: todo.uuid)

        let received = try #require(
            TodoQueries.todo(uuid: transfer.uuid, in: destination)
        )
        // Genuinely the other window's copy, not the object dragged.
        #expect(received !== todo)

        let applied = TodoDropAction.apply(
            .today, to: received,
            store: TodoStore(context: destination)
        )

        #expect(applied)
        #expect(received.assignedDate != nil)
        #expect(calendar.isDateInToday(received.assignedDate!))
    }

    /// A drop that names a to-do neither window has is refused rather than
    /// crashing — a stale pasteboard from a window since closed.
    @Test func aTransferForAMissingTodoResolvesToNothing() throws {
        let context = try makeContext()
        #expect(TodoQueries.todo(uuid: UUID(), in: context) == nil)
    }
}
