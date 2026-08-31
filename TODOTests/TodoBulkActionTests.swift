import Testing
import Foundation
import SwiftData
@testable import TODO

/// What the multi-select bar's actions do to the store.
///
/// The property most of these are really checking is that a bulk action is
/// **one** undoable entry. Looping the single-row verbs would leave a stack
/// that takes eight Cmd+Zs to walk back out of one press, and an undo toast
/// describing only the last row it happened to touch.
@MainActor
struct TodoBulkActionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Three plain to-dos, and the store over them.
    private func makeTodos(
        _ count: Int = 3,
        in context: ModelContext
    ) -> [Todo] {
        (0..<count).map { index in
            let todo = Todo(title: "Task \(index)")
            context.insert(todo)
            return todo
        }
    }

    private func freshStack() {
        UndoStack.shared.reset()
    }

    // MARK: State

    @Test func completingASelectionResolvesEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        TodoStore(context: context).setState(todos, to: .completed)

        #expect(todos.allSatisfy { $0.state == .completed })
    }

    /// The point of the bulk verbs: one press, one entry.
    @Test func completingASelectionIsASingleUndoEntry() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        TodoStore(context: context).setState(todos, to: .completed)

        #expect(UndoStack.shared.undoable.count == 1)
    }

    /// And that one entry puts all of them back.
    @Test func undoingABulkCompleteReopensEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        TodoStore(context: context).setState(todos, to: .completed)
        UndoStack.shared.undo(in: context)

        #expect(todos.allSatisfy { $0.state == .open })
    }

    /// The entry names the batch, since "Undo Complete" after clearing nine
    /// rows gives no sense of what is about to come back.
    @Test func aBulkEntryIsNamedWithItsCount() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(4, in: context)

        TodoStore(context: context).setState(todos, to: .completed)

        #expect(UndoStack.shared.undoActionName == "Complete 4 To-Dos")
    }

    /// One row selected reads as the ordinary action, not "Complete 1 To-Dos".
    @Test func aSingleRowKeepsThePlainName() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(1, in: context)

        TodoStore(context: context).setState(todos, to: .completed)

        #expect(UndoStack.shared.undoActionName == "Complete")
    }

    /// Bulk completion cascades rather than raising a prompt per blocked row:
    /// a chain of dialogs over one press is not an answerable question.
    @Test func completingAParentCascadesToItsSubtasks() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let parent = Todo(title: "Project")
        context.insert(parent)
        let child = store.addSubtask(to: parent)

        store.setState([parent], to: .completed)

        #expect(parent.state == .completed)
        #expect(child.state == .completed)
    }

    /// And undoing it puts the subtasks back too — they are rows the user
    /// never touched directly, which is exactly what undo is for.
    @Test func undoingACascadeReopensTheSubtasks() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let parent = Todo(title: "Project")
        context.insert(parent)
        let child = store.addSubtask(to: parent)

        store.setState([parent], to: .completed)
        UndoStack.shared.undo(in: context)

        #expect(parent.state == .open)
        #expect(child.state == .open)
    }

    /// A mixed batch goes one way for all of it, rather than each row flipping
    /// independently — one button that does opposite things to different rows
    /// has an unpredictable result.
    @Test func togglingAMixedSelectionCompletesTheRemainder() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        todos[0].state = .completed

        TodoStore(context: context).toggleAll(todos)

        #expect(todos.allSatisfy { $0.state == .completed })
    }

    /// A batch that is already finished reopens, so the button is a real
    /// toggle rather than a one-way trip.
    @Test func togglingAResolvedSelectionReopensIt() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        for todo in todos { todo.state = .completed }

        TodoStore(context: context).toggleAll(todos)

        #expect(todos.allSatisfy { $0.state == .open })
    }

    // MARK: Scheduling

    @Test func schedulingASelectionDatesEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        let day = Calendar.current.startOfDay(for: Date())

        TodoStore(context: context).schedule(todos, to: day)

        #expect(todos.allSatisfy { $0.assignedDate == day })
        #expect(UndoStack.shared.undoable.count == 1)
    }

    @Test func undoingABulkScheduleRestoresTheOriginalDates() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        let day = Calendar.current.startOfDay(for: Date())

        TodoStore(context: context).schedule(todos, to: day)
        UndoStack.shared.undo(in: context)

        #expect(todos.allSatisfy { $0.assignedDate == nil })
    }

    @Test func schedulingASelectionForAWeekPlansEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        TodoStore(context: context).schedule(todos, forWeek: .thisWeek)

        #expect(todos.allSatisfy { $0.weekAnchor != nil })
        #expect(UndoStack.shared.undoable.count == 1)
    }

    // MARK: Filing

    @Test func movingASelectionToASpaceFilesEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let todos = makeTodos(in: context)
        let space = store.createSpace(name: "Work")

        store.move(todos, toSpace: space)

        #expect(todos.allSatisfy { $0.space?.uuid == space.uuid })
        #expect(UndoStack.shared.undoable.count == 1)
    }

    @Test func movingASelectionIntoAProjectAdoptsEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let todos = makeTodos(in: context)
        let project = Todo(title: "Project", isProject: true)
        context.insert(project)

        store.move(todos, toParent: project)

        #expect(todos.allSatisfy { $0.parent?.uuid == project.uuid })
    }

    /// Selecting the destination along with the rows being moved is an easy
    /// mis-click, and it must not take the project out of its own list.
    @Test func movingASelectionThatContainsTheDestinationSkipsIt() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let project = Todo(title: "Project", isProject: true)
        context.insert(project)
        let todos = makeTodos(2, in: context)

        store.move(todos + [project], toParent: project)

        #expect(project.parent == nil)
        #expect(todos.allSatisfy { $0.parent?.uuid == project.uuid })
    }

    // MARK: Duplicating

    @Test func duplicatingASelectionCopiesEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        let copies = TodoStore(context: context).duplicate(todos)

        #expect(copies.count == 3)
        #expect(Set(copies.map(\.title)) == Set(todos.map(\.title)))
        // Copies, not the same objects.
        #expect(Set(copies.map(\.uuid)).isDisjoint(with: Set(todos.map(\.uuid))))
    }

    /// Undo has to remove the copies rather than restore the originals, which
    /// were never changed.
    @Test func undoingABulkDuplicateRemovesTheCopies() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        let copies = TodoStore(context: context).duplicate(todos)
        UndoStack.shared.undo(in: context)

        for copy in copies {
            #expect(TodoQueries.todo(uuid: copy.uuid, in: context) == nil)
        }
        // The originals are untouched.
        for todo in todos {
            #expect(TodoQueries.todo(uuid: todo.uuid, in: context) != nil)
        }
    }

    // MARK: Promoting

    @Test func promotingASelectionMakesEveryRowAProject() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)

        TodoStore(context: context).setIsProject(todos, true)

        #expect(todos.allSatisfy { $0.isProject })
        #expect(UndoStack.shared.undoable.count == 1)
    }

    // MARK: Deleting

    @Test func deletingASelectionRemovesEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        let ids = todos.map(\.uuid)

        TodoStore(context: context).delete(todos)

        for id in ids {
            #expect(TodoQueries.todo(uuid: id, in: context) == nil)
        }
        #expect(UndoStack.shared.undoable.count == 1)
    }

    /// One entry brings the whole batch back.
    @Test func undoingABulkDeleteRestoresEveryRow() throws {
        let context = try makeContext()
        freshStack()
        let todos = makeTodos(in: context)
        let ids = todos.map(\.uuid)

        TodoStore(context: context).delete(todos)
        UndoStack.shared.undo(in: context)

        for id in ids {
            #expect(TodoQueries.todo(uuid: id, in: context) != nil)
        }
    }

    /// Deleting a project takes its subtasks, and undo has to bring those back
    /// too — restoring only the selected rows would leave an empty project.
    @Test func undoingABulkDeleteRestoresSubtasksAndTheirLinks() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let parent = Todo(title: "Project", isProject: true)
        context.insert(parent)
        let child = store.addSubtask(to: parent, title: "Step")
        let parentID = parent.uuid
        let childID = child.uuid

        store.delete([parent])
        #expect(TodoQueries.todo(uuid: childID, in: context) == nil)

        UndoStack.shared.undo(in: context)

        let restoredChild = TodoQueries.todo(uuid: childID, in: context)
        #expect(restoredChild != nil)
        // The link has to come back with it, or the subtask returns as a
        // top-level row in whatever list it qualifies for.
        #expect(restoredChild?.parent?.uuid == parentID)
    }

    /// A selection holding both a project and one of its own subtasks is two
    /// rows to the user but one subtree to the store — deleting the child
    /// separately would be deleting it twice.
    @Test func deletingAParentAndItsChildTogetherSucceeds() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let parent = Todo(title: "Project", isProject: true)
        context.insert(parent)
        let child = store.addSubtask(to: parent, title: "Step")
        let parentID = parent.uuid
        let childID = child.uuid

        store.delete([parent, child])

        #expect(TodoQueries.todo(uuid: parentID, in: context) == nil)
        #expect(TodoQueries.todo(uuid: childID, in: context) == nil)

        // And it still comes back in one step.
        UndoStack.shared.undo(in: context)
        #expect(TodoQueries.todo(uuid: parentID, in: context) != nil)
        #expect(TodoQueries.todo(uuid: childID, in: context) != nil)
    }

    // MARK: Empty selections

    /// Every verb is a no-op on an empty selection, and — the part worth
    /// pinning — records nothing, so the bar cannot litter the undo stack with
    /// entries that would appear to do nothing when walked back.
    @Test func actionsOnAnEmptySelectionRecordNothing() throws {
        let context = try makeContext()
        freshStack()
        let store = TodoStore(context: context)
        let empty: [Todo] = []

        store.setState(empty, to: .completed)
        store.toggleAll(empty)
        store.schedule(empty, to: Date())
        store.schedule(empty, forWeek: .thisWeek)
        store.move(empty, toSpace: nil)
        store.move(empty, toParent: nil)
        store.setIsProject(empty, true)
        store.delete(empty)
        #expect(store.duplicate(empty).isEmpty)

        #expect(UndoStack.shared.undoable.isEmpty)
    }
}
