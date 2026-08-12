import Foundation
import OSLog
import SwiftData
import WidgetKit

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
    func createSpace(
        name: String,
        symbolName: String = "square.stack",
        colorHex: String = Theme.Palette.defaultSpaceColor
    ) -> Space {
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

    /// Copy a todo, placing the copy directly after the original.
    ///
    /// Deliberately shallow: the copy takes the original's own fields — title,
    /// notes, dates, duration, colour, and its place in the tree — but not its
    /// subtasks or reminders. Duplicating a project would otherwise clone an
    /// arbitrary amount of work, and a duplicated reminder is a second
    /// notification the user never asked for.
    ///
    /// The copy is *not* resolved even when the original is: duplicating a
    /// finished to-do is how the same work gets done again, so the point of the
    /// copy is that it is still open.
    @discardableResult
    func duplicate(_ todo: Todo) -> Todo {
        let copy = Todo(
            title: todo.title,
            notes: todo.notes,
            assignedDate: todo.assignedDate,
            assignedHasTime: todo.assignedHasTime,
            duration: todo.duration,
            dueDate: todo.dueDate,
            dueHasTime: todo.dueHasTime,
            isProject: todo.isProject,
            space: todo.space,
            parent: todo.parent
        )
        copy.colorHex = todo.colorHex
        context.insert(copy)

        // Slotted immediately after the original rather than appended, so the
        // copy appears next to what it was made from instead of at the bottom
        // of a list the user may have to scroll to find.
        insert(copy, after: todo)

        copy.refileForCurrentScheduling()
        save()
        return copy
    }

    /// Renumber a container so `moved` sits directly after `anchor`.
    private func insert(_ moved: Todo, after anchor: Todo) {
        var siblings = self.siblings(of: anchor).filter { $0.uuid != moved.uuid }
        guard let index = siblings.firstIndex(where: { $0.uuid == anchor.uuid }) else { return }

        siblings.insert(moved, at: index + 1)
        for (index, todo) in siblings.enumerated() {
            todo.sortIndex = index
        }
    }

    /// Todos sharing a container with `todo`, in display order.
    ///
    /// Fetched by container rather than by scanning every to-do in the store:
    /// this runs on every reorder and every drag, and a sibling set is a
    /// handful of rows however large the database is.
    private func siblings(of todo: Todo) -> [Todo] {
        let parentID = todo.parent?.uuid
        let spaceID = todo.space?.uuid

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { candidate in
                candidate.parent?.uuid == parentID && candidate.space?.uuid == spaceID
            }
        )
        descriptor.sortBy = [SortDescriptor(\Todo.sortIndex)]
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Take a scheduled todo off the calendar, leaving it otherwise untouched.
    ///
    /// Clears the assigned date rather than the due date: the calendar lays out
    /// `assignedDate`, so that is the one that decides whether a to-do appears
    /// on a day at all. A deadline is a fact about the work, not a placement,
    /// and unscheduling should not quietly discard it.
    func unschedule(_ todo: Todo) {
        update(todo) {
            $0.assignedDate = nil
            $0.assignedHasTime = false
        }
    }

    /// Append position for a new todo within its container.
    ///
    /// Each branch asks SQLite for the highest existing index rather than
    /// reading the container's contents to take a maximum: appending needs one
    /// number, and a space or project holding a year of work should not have to
    /// load it to produce that number.
    ///
    /// The subtask branch stays in memory — a parent's `subtaskList` is already
    /// faulted in by the time something is being added to it, and subtask
    /// counts are small by construction.
    private func nextSortIndex(inSpace space: Space?, parent: Todo?) -> Int {
        if let parent { return (parent.subtaskList.map(\.sortIndex).max() ?? -1) + 1 }

        let predicate: Predicate<Todo>
        if let spaceID = space?.uuid {
            predicate = #Predicate<Todo> { $0.space?.uuid == spaceID }
        } else {
            predicate = #Predicate<Todo> { $0.space == nil && $0.parent == nil }
        }

        var descriptor = FetchDescriptor<Todo>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\Todo.sortIndex, order: .reverse)]
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first?.sortIndex ?? -1) + 1
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
        let dirtyTodos = (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray).compactMap {
            $0 as? Todo
        }
        if TodoQueries.today(dirtyTodos, includeResolved: true).count > 0 {
            WidgetCenter.shared.reloadAllTimelines()
        }
        do {
            try context.save()
        } catch {
            AppLog.data.error("Save failed: \(error, privacy: .public)")
        }
    }
}
