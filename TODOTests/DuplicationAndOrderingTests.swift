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

    /// The requested order: now, soon, later, unscheduled, then past.
    @Test func widgetOrdersByUrgencyBand() throws {
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

    /// An item with no duration stops being "now" once its default slot runs
    /// out, rather than staying current for the rest of the day.
    @Test func untimedDurationFallsBackToTheNowWindow() throws {
        let store = try makeStore()
        let now = Date()

        let justStarted = timed(store, "Just started", at: now.addingTimeInterval(-60))
        let longDone = timed(store, "Long done", at: now.addingTimeInterval(-3600))

        #expect(TodoQueries.widgetRank(for: justStarted, now: now) == .now)
        #expect(TodoQueries.widgetRank(for: longDone, now: now) == .past)
    }

    /// A due date is not a schedule, so a due-dated item ranks as unscheduled.
    @Test func dueDateAloneIsUnscheduled() throws {
        let store = try makeStore()
        let now = Date()
        let todo = store.createTodo(title: "Due", dueDate: now.addingTimeInterval(3600))

        #expect(TodoQueries.widgetRank(for: todo, now: now) == .unscheduled)
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
