import Testing
import Foundation
import SwiftData
@testable import TODO

/// Model-layer rules: schema validity, subtask gating, and Inbox/Anytime filing.
@MainActor
struct ModelTests {

    /// Fresh in-memory container per test so cases stay independent.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    // MARK: Schema

    /// The schema must load with every entity present. This is also the guard
    /// against CloudKit-incompatible changes: mirroring requires optional or
    /// defaulted properties and no unique constraints, so a violation here
    /// means sync would fail at runtime.
    @Test func schemaLoadsWithAllEntities() throws {
        let container = try ModelContainer.appContainer(inMemory: true)
        let names = Set(container.schema.entities.map(\.name))
        #expect(names == ["Todo", "Space", "Reminder", "SavedAISummary"])
    }

    /// Every attribute must be optional or carry a default value, and none may
    /// be unique — the two constraints CloudKit mirroring imposes.
    @Test func schemaIsCloudKitCompatible() throws {
        let container = try ModelContainer.appContainer(inMemory: true)
        for entity in container.schema.entities {
            for property in entity.properties {
                guard let attribute = property as? Schema.Attribute else { continue }
                #expect(
                    !attribute.isUnique,
                    "\(entity.name).\(attribute.name) is unique; CloudKit forbids unique constraints"
                )
                #expect(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "\(entity.name).\(attribute.name) must be optional or defaulted for CloudKit"
                )
            }
        }
    }

    // MARK: Subtask completion rules

    /// A parent with unresolved subtasks refuses to complete, and says so by
    /// returning false rather than silently doing nothing.
    @Test func parentCannotCompleteWithOpenSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)

        #expect(parent.canTransition(to: .completed) == false)
        #expect(parent.setState(.completed) == false)
        #expect(parent.state == .open, "state must not change when blocked")
    }

    /// Cascading resolves the subtasks along with the parent — the "yes, mark
    /// them all" branch of the spec's prompt.
    @Test func cascadeCompletesSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let a = Todo(title: "A")
        let b = Todo(title: "B")
        context.insert(parent)
        context.insert(a)
        context.insert(b)
        parent.addSubtask(a)
        parent.addSubtask(b)

        #expect(parent.setState(.completed, cascadeToSubtasks: true) == true)
        #expect(parent.state == .completed)
        #expect(a.state == .completed)
        #expect(b.state == .completed)
    }

    /// Cancelling cascades the same way, since `cancelled` is also a resolved
    /// state under the spec.
    @Test func cascadeCancelsSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)

        #expect(parent.setState(.cancelled, cascadeToSubtasks: true) == true)
        #expect(child.state == .cancelled)
    }

    /// A subtask that is already cancelled does not block the parent.
    @Test func resolvedSubtasksDoNotBlock() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)
        child.setState(.cancelled)

        #expect(parent.blockingSubtasks.isEmpty)
        #expect(parent.setState(.completed) == true)
    }

    /// Nothing blocks a move back to an unresolved state.
    @Test func reopeningIsNeverBlocked() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)

        #expect(parent.canTransition(to: .started))
        #expect(parent.setState(.started) == true)
        #expect(parent.state == .started)
    }

    /// Resolving stamps `resolvedAt`; reopening clears it.
    @Test func resolvedAtTracksState() throws {
        let context = try makeContext()
        let todo = Todo(title: "Solo")
        context.insert(todo)

        todo.setState(.completed)
        #expect(todo.resolvedAt != nil)

        todo.setState(.open)
        #expect(todo.resolvedAt == nil)
    }

    // MARK: Filing rules

    /// A bare todo starts in the Inbox.
    @Test func newTodoStartsInInbox() throws {
        let context = try makeContext()
        let todo = Todo(title: "Unfiled")
        context.insert(todo)
        #expect(todo.bucket == .inbox)
        #expect(todo.isScheduled == false)
    }

    /// Assigning a date moves a todo out of the Inbox into Anytime.
    @Test func assigningDateMovesToAnytime() throws {
        let context = try makeContext()
        let todo = Todo(title: "Dated")
        context.insert(todo)

        todo.assignedDate = Date()
        todo.refileForCurrentScheduling()

        #expect(todo.bucket == .anytime)
        #expect(todo.isScheduled)
    }

    /// A due date alone is also enough to count as scheduled.
    @Test func dueDateMovesToAnytime() throws {
        let context = try makeContext()
        let todo = Todo(title: "Due")
        context.insert(todo)

        todo.dueDate = Date()
        todo.refileForCurrentScheduling()

        #expect(todo.bucket == .anytime)
    }

    /// Clearing every date sends an unfiled todo back to the Inbox.
    @Test func clearingDatesReturnsToInbox() throws {
        let context = try makeContext()
        let todo = Todo(title: "Dated", assignedDate: Date())
        context.insert(todo)
        #expect(todo.bucket == .anytime)

        todo.assignedDate = nil
        todo.refileForCurrentScheduling()

        #expect(todo.bucket == .inbox)
    }

    /// Filing into a space counts as scheduling even with no date.
    @Test func movingToSpaceSchedules() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let todo = Todo(title: "Filed")
        context.insert(space)
        context.insert(todo)

        todo.move(toSpace: space)

        #expect(todo.bucket == .space)
        #expect(todo.space === space)
        #expect(todo.isScheduled)
    }

    // MARK: Nesting rules

    /// Promoting to a project detaches it from any parent, enforcing the
    /// single level of nesting (spaces contain projects).
    @Test func promotingToProjectDetachesParent() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)
        #expect(child.parent === parent)

        child.setIsProject(true)

        #expect(child.isProject)
        #expect(child.parent == nil)
    }

    /// A subtask inherits its parent's space so it appears in the same section.
    @Test func subtaskInheritsParentSpace() throws {
        let context = try makeContext()
        let space = Space(name: "Home")
        let project = Todo(title: "Project", isProject: true)
        let child = Todo(title: "Child")
        context.insert(space)
        context.insert(project)
        context.insert(child)

        project.move(toSpace: space)
        project.addSubtask(child)

        #expect(child.space === space)
    }

    /// Moving a todo directly into a space clears any parent link.
    @Test func movingToSpaceClearsParent() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(space)
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)

        child.move(toSpace: space)

        #expect(child.parent == nil)
        #expect(child.space === space)
    }

    /// A space lists only its projects, not loose todos.
    @Test func spaceSeparatesProjectsFromLooseTodos() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let project = Todo(title: "Project", isProject: true)
        let loose = Todo(title: "Loose")
        context.insert(space)
        context.insert(project)
        context.insert(loose)

        project.move(toSpace: space)
        loose.move(toSpace: space)

        #expect(space.projects.count == 1)
        #expect(space.looseTodos.count == 1)
        #expect(space.openCount == 1, "projects are excluded from the badge count")
    }

    // MARK: Duration and overdue

    /// A timed todo with no duration falls back to the configured default.
    @Test func durationFallsBackToDefault() throws {
        let todo = Todo(title: "Meeting")
        #expect(todo.effectiveDuration(defaultDuration: 900) == 900)

        todo.duration = 1800
        #expect(todo.effectiveDuration(defaultDuration: 900) == 1800)
    }

    /// Overdue means a past due date on unresolved work only.
    @Test func overdueIgnoresResolvedTodos() throws {
        let context = try makeContext()
        let todo = Todo(title: "Late")
        context.insert(todo)
        todo.dueDate = Date().addingTimeInterval(-3600)

        #expect(todo.isOverdue)

        todo.setState(.completed)
        #expect(todo.isOverdue == false)
    }

    /// Deleting a parent removes its subtasks via the cascade rule.
    @Test func deletingParentCascadesToSubtasks() throws {
        let container = try ModelContainer.appContainer(inMemory: true)
        let context = ModelContext(container)
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        context.insert(parent)
        context.insert(child)
        parent.addSubtask(child)
        try context.save()

        context.delete(parent)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Todo>())
        #expect(remaining.isEmpty)
    }
}
