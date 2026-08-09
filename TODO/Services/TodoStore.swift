import Foundation
import OSLog
import SwiftData

/// Every mutation the app performs on todos, in one place.
///
/// The UI, and later the App Intents layer, the widget, and the macOS CLI, all
/// go through this type rather than touching `ModelContext` directly. That
/// keeps the completion and filing rules in a single place and gives the future
/// surfaces a ready-made API — see `FutureFeatures.md`.
@MainActor
struct TodoStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Creating

    /// Create a todo. With no date and no home it lands in the Inbox, per the
    /// spec's default.
    @discardableResult
    func createTodo(
        title: String = "",
        notes: String = "",
        space: Space? = nil,
        parent: Todo? = nil,
        assignedDate: Date? = nil,
        dueDate: Date? = nil,
        isProject: Bool = false
    ) -> Todo {
        let todo = Todo(
            title: title,
            notes: notes,
            assignedDate: assignedDate,
            dueDate: dueDate,
            isProject: isProject,
            space: space,
            parent: parent
        )
        todo.sortIndex = nextSortIndex(inSpace: space, parent: parent)
        context.insert(todo)
        todo.refileForCurrentScheduling()
        save()
        return todo
    }

    @discardableResult
    func createSpace(name: String, symbolName: String = "square.stack", colorHex: String = "#8E8E93") -> Space {
        let existing = (try? context.fetch(FetchDescriptor<Space>())) ?? []
        let space = Space(
            name: name,
            symbolName: symbolName,
            colorHex: colorHex,
            sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1
        )
        context.insert(space)
        save()
        return space
    }

    /// Append position for a new todo within its container.
    private func nextSortIndex(inSpace space: Space?, parent: Todo?) -> Int {
        if let parent { return (parent.subtaskList.map(\.sortIndex).max() ?? -1) + 1 }
        if let space { return (space.todoList.map(\.sortIndex).max() ?? -1) + 1 }
        let all = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        return (all.filter { $0.space == nil && $0.parent == nil }.map(\.sortIndex).max() ?? -1) + 1
    }
    

    // MARK: Completion

    /// Result of attempting a state change, so the UI knows when to prompt.
    enum StateChangeOutcome: Equatable {
        case applied
        /// Blocked by unresolved subtasks; the UI should ask whether to cascade.
        case needsSubtaskConfirmation(count: Int)
    }

    /// Attempt a state change, reporting when subtask confirmation is required.
    ///
    /// The spec: if a user tries to complete or cancel a todo with unfinished
    /// subtasks, ask whether to resolve those too.
    func setState(_ todo: Todo, to newState: CompletionState) -> StateChangeOutcome {
        if todo.setState(newState) {
            save()
            return .applied
        }
        return .needsSubtaskConfirmation(count: todo.blockingSubtasks.count)
    }

    /// Apply a state change after the user confirms the cascade.
    func setStateCascading(_ todo: Todo, to newState: CompletionState) {
        todo.setState(newState, cascadeToSubtasks: true)
        save()
    }

    /// The checkbox tap: complete an open item, reopen a resolved one.
    func toggle(_ todo: Todo) -> StateChangeOutcome {
        setState(todo, to: todo.toggledState)
    }

    // MARK: Editing

    /// Apply an edit and refile, since dates and placement affect the bucket.
    ///
    /// An edit that moves the todo somewhere the user has not looked — giving
    /// it a date, or filing it elsewhere — re-flags it as new.
    func update(_ todo: Todo, _ mutate: (Todo) -> Void) {
        mutate(todo)
        todo.refileForCurrentScheduling()
        todo.refreshNewFlagAfterPlacementChange()
        todo.touch()
        save()
    }

    /// Mark every todo shown in a list as viewed, clearing their dots.
    func markAsViewed(_ todos: [Todo]) {
        let unseen = todos.filter(\.isNew)
        guard !unseen.isEmpty else { return }

        for todo in unseen {
            todo.markAsViewed()
        }
        save()
    }

    func move(_ todo: Todo, toSpace space: Space?) {
        todo.move(toSpace: space)
        save()
    }

    func move(_ todo: Todo, toParent parent: Todo?) {
        todo.move(toParent: parent)
        save()
    }

    /// Promote a todo to a project so it appears in the sidebar, or demote it.
    func setIsProject(_ todo: Todo, _ promoted: Bool) {
        todo.setIsProject(promoted)
        save()
    }

    @discardableResult
    func addSubtask(to parent: Todo, title: String = "") -> Todo {
        let subtask = Todo(title: title)
        context.insert(subtask)
        parent.addSubtask(subtask)
        save()
        return subtask
    }

    /// Re-file an existing todo as a subtask of `parent`.
    ///
    /// Unlike `addSubtask(to:)` this creates nothing — it moves a todo that
    /// already exists, which is how an item captured in the Inbox later becomes
    /// part of a project. Returns `false` without changing anything when the
    /// move would make the tree circular.
    @discardableResult
    func adopt(_ todo: Todo, asSubtaskOf parent: Todo) -> Bool {
        guard parent.canAdopt(todo) else { return false }

        parent.addSubtask(todo)
        // Adopting is a placement change, so the item re-flags as new in the
        // project the user is about to see it in.
        todo.refreshNewFlagAfterPlacementChange()
        parent.touch()
        save()
        return true
    }

    /// Detach a subtask from its parent, leaving it as a standalone todo.
    func detachFromParent(_ todo: Todo) {
        todo.move(toParent: nil)
        save()
    }

    // MARK: Reminders

    @discardableResult
    func addDateReminder(to todo: Todo, at date: Date) -> Reminder {
        let reminder = Reminder(kind: .dateTime, fireDate: date, todo: todo)
        context.insert(reminder)
        save()
        return reminder
    }

    @discardableResult
    func addLocationReminder(
        to todo: Todo,
        latitude: Double,
        longitude: Double,
        radius: Double = 100,
        placeName: String?,
        trigger: LocationTrigger = .onArrival
    ) -> Reminder {
        let reminder = Reminder(
            kind: .location,
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            placeName: placeName,
            trigger: trigger,
            todo: todo
        )
        context.insert(reminder)
        save()
        return reminder
    }

    // MARK: Deleting

    func delete(_ todo: Todo) {
        context.delete(todo)
        save()
    }

    func delete(_ space: Space) {
        context.delete(space)
        save()
    }

    func delete(_ reminder: Reminder) {
        context.delete(reminder)
        save()
    }

    // MARK: Ordering

    /// Persist a manual reordering.
    func reorder(_ todos: [Todo]) {
        for (index, todo) in todos.enumerated() {
            todo.sortIndex = index
        }
        save()
    }

    func reorder(spaces: [Space]) {
        for (index, space) in spaces.enumerated() {
            space.sortIndex = index
        }
        save()
    }
    
    // MARK: AI Summary
    
    func updateAISummary(_ summary: SavedAISummary) {
        do {
            try context.delete(model: SavedAISummary.self, where: #Predicate { _ in
                true
            })
            context.insert(summary)
            try context.save()
        } catch {
            AppLog.data.error("Save failed: \(error, privacy: .public)")
        }
    }

    // MARK: Persistence

    /// Save, logging rather than trapping — a failed save should not take the
    /// app down mid-edit.
    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.data.error("Save failed: \(error, privacy: .public)")
        }
    }
}
