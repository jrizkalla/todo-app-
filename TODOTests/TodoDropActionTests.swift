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
            store: TodoStore(context: context),
            allTodos: [todo], spaces: []
        )

        #expect(applied)
        #expect(todo.assignedDate != nil)
        #expect(calendar.isDateInToday(todo.assignedDate!))
        #expect(todo.assignedHasTime == false)
        // The point of the rule: it is now in the list it was dropped on.
        #expect(TodoQueries.today([todo]).contains { $0.uuid == todo.uuid })
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
            store: store, allTodos: [todo], spaces: [space]
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
            store: store, allTodos: [todo], spaces: [space]
        )

        #expect(todo.assignedDate == nil)
        // The home survives — that is what separates Anytime from the Inbox.
        #expect(todo.space?.uuid == space.uuid)
    }

    @Test func dropOnThisWeekSchedulesIt() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        TodoDropAction.apply(
            .thisWeek, to: todo,
            store: TodoStore(context: context),
            allTodos: [todo], spaces: []
        )

        #expect(todo.assignedDate != nil)
        #expect(TodoQueries.thisWeek([todo]).contains { $0.uuid == todo.uuid })
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
            store: store, allTodos: [todo], spaces: [space]
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
            store: store, allTodos: [project, todo], spaces: [space]
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
            store: store, allTodos: [project, todo], spaces: []
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
            store: TodoStore(context: context),
            allTodos: [project], spaces: []
        )

        #expect(applied == false)
        #expect(project.parent == nil)
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
            store: TodoStore(context: context),
            allTodos: [todo], spaces: []
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
            store: TodoStore(context: context),
            allTodos: [todo], spaces: []
        )

        #expect(applied == false)
    }
}
