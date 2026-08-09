import Testing
import Foundation
import SwiftData
@testable import TODO

/// Re-filing an existing todo as somebody else's subtask.
///
/// The dangerous case is a cycle: parenting an ancestor under its own
/// descendant makes `orderedSubtasks` walks non-terminating, so the guard is
/// worth pinning from several directions.
@MainActor
struct SubtaskAdoptionTests {

    /// Fresh in-memory store per test so cases stay independent.
    ///
    /// A dedicated `ModelContext` rather than the container's `mainContext`:
    /// these tests run in parallel, and sharing one context across them is not
    /// safe.
    private func makeStore() throws -> (TodoStore, ModelContext) {
        let container = try ModelContainer.appContainer(inMemory: true)
        let context = ModelContext(container)
        return (TodoStore(context: context), context)
    }

    @Test func adoptingMovesAnExistingTodoUnderTheParent() throws {
        let (store, _) = try makeStore()

        let project = store.createTodo(title: "Launch", isProject: true)
        let loose = store.createTodo(title: "Write copy")

        #expect(loose.parent == nil)

        let didAdopt = store.adopt(loose, asSubtaskOf: project)

        #expect(didAdopt)
        #expect(loose.parent?.uuid == project.uuid)
        #expect(project.orderedSubtasks.map(\.uuid) == [loose.uuid])
    }

    /// Adopting keeps the same object, so notes, dates, and reminders survive
    /// the move — that is the whole point over retyping it.
    @Test func adoptingPreservesTheTodosContent() throws {
        let (store, _) = try makeStore()

        let project = store.createTodo(title: "Launch", isProject: true)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = store.createTodo(title: "Book venue", notes: "Call first", dueDate: due)

        store.adopt(existing, asSubtaskOf: project)

        #expect(existing.notes == "Call first")
        #expect(existing.dueDate == due)
        #expect(existing.title == "Book venue")
    }

    @Test func aTodoCannotAdoptItself() throws {
        let (store, _) = try makeStore()
        let todo = store.createTodo(title: "Solo")

        #expect(!todo.canAdopt(todo))
        #expect(!store.adopt(todo, asSubtaskOf: todo))
        #expect(todo.parent == nil)
    }

    /// The core cycle guard: a grandparent must not become a child of its own
    /// grandchild.
    @Test func adoptingAnAncestorIsRejected() throws {
        let (store, _) = try makeStore()

        let root = store.createTodo(title: "Root")
        let middle = store.createTodo(title: "Middle")
        let leaf = store.createTodo(title: "Leaf")

        store.adopt(middle, asSubtaskOf: root)
        store.adopt(leaf, asSubtaskOf: middle)

        // Both the direct parent and the grandparent are ancestors of `leaf`.
        #expect(!leaf.canAdopt(middle))
        #expect(!leaf.canAdopt(root))
        #expect(!store.adopt(root, asSubtaskOf: leaf))

        // The original chain is untouched.
        #expect(root.parent == nil)
        #expect(middle.parent?.uuid == root.uuid)
        #expect(leaf.parent?.uuid == middle.uuid)
    }

    @Test func alreadyAttachedChildIsNotOfferedAgain() throws {
        let (store, _) = try makeStore()

        let project = store.createTodo(title: "Launch", isProject: true)
        let child = store.createTodo(title: "Task")
        store.adopt(child, asSubtaskOf: project)

        #expect(!project.canAdopt(child))
    }

    /// Projects are top-level containers, so they never become subtasks.
    @Test func projectsAreNotAdoptable() throws {
        let (store, _) = try makeStore()

        let host = store.createTodo(title: "Host", isProject: true)
        let other = store.createTodo(title: "Other project", isProject: true)

        #expect(!host.canAdopt(other))
    }

    /// Moving a todo that already belongs to someone else reparents it rather
    /// than attaching it twice.
    @Test func adoptingFromAnotherParentReparents() throws {
        let (store, _) = try makeStore()

        let first = store.createTodo(title: "First", isProject: true)
        let second = store.createTodo(title: "Second", isProject: true)
        let child = store.createTodo(title: "Shared")

        store.adopt(child, asSubtaskOf: first)
        store.adopt(child, asSubtaskOf: second)

        #expect(child.parent?.uuid == second.uuid)
        #expect(first.orderedSubtasks.isEmpty)
        #expect(second.orderedSubtasks.map(\.uuid) == [child.uuid])
    }

    @Test func detachingLeavesTheTodoStandingAlone() throws {
        let (store, _) = try makeStore()

        let project = store.createTodo(title: "Launch", isProject: true)
        let child = store.createTodo(title: "Task")
        store.adopt(child, asSubtaskOf: project)

        store.detachFromParent(child)

        #expect(child.parent == nil)
        #expect(project.orderedSubtasks.isEmpty)
    }

    /// `ancestors` must terminate even on a store that already contains a
    /// cycle, so a corrupt row cannot hang the UI.
    @Test func ancestorWalkTerminatesOnAPreexistingCycle() throws {
        let (store, _) = try makeStore()

        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")

        // Bypass the guard to build the cycle the guard normally prevents.
        a.parent = b
        b.parent = a

        #expect(a.ancestors.count <= 2)
        #expect(b.ancestors.count <= 2)
    }
}
