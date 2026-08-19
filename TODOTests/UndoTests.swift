import Testing
import Foundation
import SwiftData
@testable import TODO

/// Undo and redo for the actions that take a row off the screen it was on.
@MainActor
struct UndoTests {

    private func makeStore() throws -> TodoStore {
        UndoStack.shared.reset()
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    private var stack: UndoStack { .shared }

    // MARK: Scheduling

    /// The brief's example: scheduling makes a to-do leave the list, so undo
    /// has to put the date back exactly as it was.
    @Test func undoRestoresAnUnscheduledTodo() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")
        #expect(todo.assignedDate == nil)

        store.schedule(todo, to: Date(), hasTime: true)
        #expect(todo.assignedDate != nil)

        stack.undo(in: store.context)
        #expect(todo.assignedDate == nil)
        #expect(todo.assignedHasTime == false)
    }

    @Test func redoReappliesTheSchedule() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        store.schedule(todo, to: when, hasTime: true)
        stack.undo(in: store.context)
        stack.redo(in: store.context)

        #expect(todo.assignedDate == when)
        #expect(todo.assignedHasTime)
    }

    // MARK: Completion

    @Test func undoReopensACompletedTodo() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Ship it")

        #expect(store.setState(todo, to: .completed) == .applied)
        #expect(todo.state == .completed)
        #expect(todo.resolvedAt != nil)

        stack.undo(in: store.context)
        #expect(todo.state == .open)
        #expect(todo.resolvedAt == nil)
    }

    /// A cascade resolves rows the user never touched, so undo has to reopen
    /// the whole subtree rather than only the parent.
    @Test func undoReversesACascade() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let a = store.addSubtask(to: project, title: "A")
        let b = store.addSubtask(to: project, title: "B")

        store.setStateCascading(project, to: .completed)
        #expect(project.state == .completed)
        #expect(a.state == .completed)
        #expect(b.state == .completed)

        stack.undo(in: store.context)
        #expect(project.state == .open)
        #expect(a.state == .open)
        #expect(b.state == .open)
    }

    // MARK: Deleting

    @Test func undoRestoresADeletedTodo() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Renew passport")
        let id = todo.uuid

        store.delete(todo)
        #expect(TodoQueries.todo(uuid: id, in: store.context) == nil)

        stack.undo(in: store.context)

        let restored = try #require(TodoQueries.todo(uuid: id, in: store.context))
        #expect(restored.title == "Renew passport")
    }

    /// Deleting a project takes its subtasks with it, so undo has to bring the
    /// whole subtree back — and re-link it.
    @Test func undoRestoresADeletedSubtree() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let subtask = store.addSubtask(to: project, title: "Book the venue")
        let projectID = project.uuid
        let subtaskID = subtask.uuid

        store.delete(project)
        #expect(TodoQueries.todo(uuid: subtaskID, in: store.context) == nil)

        stack.undo(in: store.context)

        let restoredProject = try #require(TodoQueries.todo(uuid: projectID, in: store.context))
        let restoredSubtask = try #require(TodoQueries.todo(uuid: subtaskID, in: store.context))
        #expect(restoredSubtask.parent?.uuid == restoredProject.uuid)
        #expect(restoredProject.orderedSubtasks.map(\.title) == ["Book the venue"])
    }

    // MARK: Moving

    @Test func undoRestoresThePreviousSpace() throws {
        let store = try makeStore()
        let work = store.createSpace(name: "Work")
        let home = store.createSpace(name: "Home")
        let todo = store.createTodo(title: "Taxes", space: work)

        store.move(todo, toSpace: home)
        #expect(todo.space?.uuid == home.uuid)

        stack.undo(in: store.context)
        #expect(todo.space?.uuid == work.uuid)
    }

    // MARK: Duplication

    @Test func undoRemovesTheDuplicate() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        let copy = store.duplicate(todo)
        let copyID = copy.uuid

        stack.undo(in: store.context)

        #expect(TodoQueries.todo(uuid: copyID, in: store.context) == nil)
        // The original is untouched.
        #expect(TodoQueries.todo(uuid: todo.uuid, in: store.context) != nil)
    }

    // MARK: Stack behaviour

    /// A drop runs several store verbs; undoing it must take one step, not one
    /// per verb.
    @Test func aCompoundDropIsOneUndoEntry() throws {
        let store = try makeStore()
        let space = store.createSpace(name: "Work")
        let todo = store.createTodo(title: "Taxes", space: space, assignedDate: Date())

        let before = stack.undoable.count
        _ = TodoDropAction.apply(.inbox, to: todo, store: store)

        #expect(stack.undoable.count == before + 1)

        stack.undo(in: store.context)
        #expect(todo.space?.uuid == space.uuid)
        #expect(todo.assignedDate != nil)
    }

    /// Editing a title is not recorded: the text is still in front of the user.
    @Test func ordinaryEditsAreNotRecorded() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        let before = stack.undoable.count
        store.update(todo) { $0.title = "Oat milk" }

        #expect(stack.undoable.count == before)
    }

    /// A new action invalidates the branch the user had undone.
    @Test func recordingClearsTheRedoStack() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        store.schedule(todo, to: Date())
        stack.undo(in: store.context)
        #expect(stack.canRedo)

        store.setState(todo, to: .completed)
        #expect(!stack.canRedo)
    }

    /// Walking the stack must not grow it: reverting runs the same store verbs
    /// the user does.
    @Test func undoingDoesNotRecordNewEntries() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        store.schedule(todo, to: Date())
        #expect(stack.undoable.count == 1)

        stack.undo(in: store.context)
        #expect(stack.undoable.isEmpty)
        #expect(stack.redoable.count == 1)
    }

    @Test func historyIsBounded() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        for day in 0..<(UndoStack.limit + 10) {
            store.schedule(todo, to: Date().addingTimeInterval(Double(day) * 86_400))
        }

        #expect(stack.undoable.count == UndoStack.limit)
    }

    /// The toast offers the latest action and goes away once it is taken.
    @Test func theToastTracksTheLatestAction() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Milk")

        store.schedule(todo, to: Date())
        #expect(stack.toast?.name == "Schedule")

        store.setState(todo, to: .completed)
        #expect(stack.toast?.name == "Complete")

        stack.undo(in: store.context)
        #expect(stack.toast == nil)
    }
}
