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

    /// Copy a todo and its subtasks, placing the copy directly after the
    /// original.
    ///
    /// The copy takes the original's own fields — title, notes, dates,
    /// duration, colour, and its place in the tree — and recursively its
    /// subtasks, since a project is defined by the work under it and a copy
    /// that arrived empty would not be a copy of that project.
    ///
    /// Reminders are deliberately *not* copied: a duplicated reminder is a
    /// second notification the user never asked for.
    ///
    /// The copy is *not* resolved even when the original is: duplicating a
    /// finished to-do is how the same work gets done again, so the point of the
    /// copy is that it is still open. The same applies to the subtasks.
    @discardableResult
    func duplicate(_ todo: Todo) -> Todo {
        let copy = copyTree(of: todo, parent: todo.parent, space: todo.space)

        // Slotted immediately after the original rather than appended, so the
        // copy appears next to what it was made from instead of at the bottom
        // of a list the user may have to scroll to find.
        insert(copy, after: todo)

        save()

        // Undoing a duplicate removes the copy: the original is untouched, so
        // there is nothing to restore, only something to take away. Redo makes
        // a fresh copy of the original rather than resurrecting this one.
        let copyID = copy.uuid
        let sourceID = todo.uuid
        UndoStack.shared.record(
            UndoableAction(
                name: "Duplicate",
                revert: { context in
                    let store = TodoStore(context: context)
                    guard let live = TodoQueries.todo(uuid: copyID, in: context) else { return }
                    context.delete(live)
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    guard let source = TodoQueries.todo(uuid: sourceID, in: context) else { return }
                    _ = store.duplicate(source)
                }
            )
        )
        return copy
    }

    /// Copy one todo and everything beneath it.
    ///
    /// Duplicating a project has to bring its subtasks: a project *is* its
    /// checklist, and a copy that arrived empty was not the thing the user
    /// asked for. Recursive rather than one level deep, because a subtask can
    /// itself be a project with children of its own.
    ///
    /// Children keep their `sortIndex` so the copy reads in the same order as
    /// the original; only the top-level copy is re-slotted, by the caller.
    private func copyTree(of todo: Todo, parent: Todo?, space: Space?) -> Todo {
        let copy = Todo(
            title: todo.title,
            notes: todo.notes,
            assignedDate: todo.assignedDate,
            assignedHasTime: todo.assignedHasTime,
            duration: todo.duration,
            dueDate: todo.dueDate,
            dueHasTime: todo.dueHasTime,
            isProject: todo.isProject,
            space: space,
            parent: parent
        )
        copy.colorHex = todo.colorHex
        copy.sortIndex = todo.sortIndex
        context.insert(copy)
        copy.refileForCurrentScheduling()

        for child in todo.orderedSubtasks {
            // The child's space follows the copied parent rather than the
            // original's, so duplicating into a different container does not
            // leave the children pointing at the old one.
            _ = copyTree(of: child, parent: copy, space: child.space)
        }

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
        recordingUndo("Unschedule", on: todo) {
            update(todo) {
                $0.assignedDate = nil
                $0.assignedHasTime = false
            }
        }
    }

    /// Schedule a to-do, recording the move so it can be put back.
    ///
    /// Separate from `update` because this is the action the brief calls out:
    /// giving something a date makes it disappear from the list the user was
    /// looking at, and undo is what saves them hunting for it.
    func schedule(_ todo: Todo, to date: Date?, hasTime: Bool = false) {
        recordingUndo("Schedule", on: todo) {
            update(todo) {
                $0.assignedDate = date
                $0.assignedHasTime = hasTime
            }
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
        guard todo.canTransition(to: newState) else {
            return .needsSubtaskConfirmation(count: todo.blockingSubtasks.count)
        }

        let wasResolved = todo.state.isResolved
        recordingUndo(undoName(for: newState), on: todo) {
            _ = todo.setState(newState)
            save()
        }
        advanceRecurrence(for: todo, wasResolved: wasResolved, isResolved: newState.isResolved)
        return .applied
    }

    /// Apply a state change after the user confirms the cascade.
    ///
    /// Recorded across the subtasks as well as the parent: the cascade is the
    /// part the user could not undo by hand, since it resolved rows they never
    /// touched directly.
    func setStateCascading(_ todo: Todo, to newState: CompletionState) {
        let affected = [todo] + todo.descendants

        let wasResolved = todo.state.isResolved
        recordingUndo(undoName(for: newState), on: affected) {
            todo.setState(newState, cascadeToSubtasks: true)
            save()
        }
        advanceRecurrence(for: todo, wasResolved: wasResolved, isResolved: newState.isResolved)
    }

    /// Let a recurring series react to one of its instances changing state.
    ///
    /// Both directions matter, and only on the *edge*: resolving an instance is
    /// what earns the next one, and reopening it has to take that successor
    /// back. Gated on the transition rather than the new state so that
    /// re-completing an already-completed to-do — which the status picker
    /// allows — does not generate a second occurrence.
    private func advanceRecurrence(for todo: Todo, wasResolved: Bool, isResolved: Bool) {
        guard todo.isRecurrenceInstance, wasResolved != isResolved else { return }
        let engine = RecurrenceEngine(context: context)

        if isResolved {
            engine.handleResolution(of: todo)
        } else {
            engine.handleReopening(of: todo)
        }
    }

    /// What the Edit menu and the toast call a state change.
    private func undoName(for state: CompletionState) -> String {
        switch state {
        case .completed: "Complete"
        case .cancelled: "Cancel"
        case .started: "Start"
        case .open: "Reopen"
        }
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
        recordingUndo("Move", on: todo) {
            todo.move(toSpace: space)
            save()
        }
    }

    func move(_ todo: Todo, toParent parent: Todo?) {
        recordingUndo("Move", on: todo) {
            todo.move(toParent: parent)
            save()
        }
    }

    /// Promote a todo to a project so it appears in the sidebar, or demote it.
    func setIsProject(_ todo: Todo, _ promoted: Bool) {
        recordingUndo(promoted ? "Make Project" : "Make To-Do", on: todo) {
            todo.setIsProject(promoted)
            save()
        }
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

    // MARK: Recurrence

    /// Make a to-do repeat, or change the schedule it repeats on.
    ///
    /// Which to-do this is called on matters, and the caller should not have to
    /// think about it: the rule always lands on the *template*, so applying a
    /// schedule from an instance's row edits the series rather than turning
    /// that one occurrence into a second template.
    ///
    /// Setting a rule on a plain to-do converts it in place: it becomes the
    /// template and its first occurrence is generated immediately, so the user
    /// sees a row appear rather than the one they were looking at vanishing.
    func setRecurrence(_ rule: RecurrenceRule?, on todo: Todo) {
        let template = todo.recurrenceRoot ?? todo
        let previous = template.recurrenceRule

        recordingUndo(previous == nil ? "Repeat" : "Change Repeat", on: template) {
            template.recurrenceRule = rule

            if rule == nil {
                // No longer a series. Instances are cut loose rather than
                // deleted — they are real work, some of it already done.
                for instance in template.recurrenceInstanceList {
                    instance.recurrenceTemplate = nil
                }
            } else if previous?.normalized() != rule?.normalized() {
                // The schedule moved, so any not-yet-touched future occurrence
                // is now on the wrong date. Recomputed from scratch below.
                template.recurrenceNextDate = nil
                discardUntouchedFutureInstances(of: template)
            }

            if rule != nil {
                // Becoming a template means giving up one-off scheduling: the
                // dates belong to the occurrences now. Runs after the branch
                // above so a changed schedule has already cleared
                // `recurrenceNextDate` and the assigned date can seed it
                // afresh, and before the refile so the bucket is decided on
                // what the template actually carries.
                template.clearScheduleForTemplate()
            }

            template.refileForCurrentScheduling()
            template.touch()
            save()
        }

        if let rule, rule.status.generatesInstances {
            RecurrenceEngine(context: context).generateInstances(for: template)
            save()
        }
    }

    /// Pause or resume a series.
    ///
    /// Pausing takes the pending occurrence with it: the spec asks a paused
    /// series to show as the template in Anytime, and leaving a live instance
    /// on Today would contradict that. Resuming regenerates from the current
    /// date rather than the one it was paused on, so a series paused for a
    /// month does not come back overdue.
    func setRecurrenceStatus(_ status: RecurrenceStatus, on todo: Todo) {
        guard let template = todo.recurrenceRoot, var rule = template.recurrenceRule else { return }

        let name = switch status {
        case .active: "Resume Repeat"
        case .paused: "Pause Repeat"
        case .cancelled: "Cancel Repeat"
        }

        recordingUndo(name, on: template) {
            rule.status = status
            template.recurrenceRule = rule

            if !status.generatesInstances {
                discardUntouchedFutureInstances(of: template)
            } else {
                // Recomputed on resume so the series picks up from now.
                template.recurrenceNextDate = nil
            }

            template.refileForCurrentScheduling()
            template.touch()
            save()
        }

        if status.generatesInstances {
            RecurrenceEngine(context: context).generateInstances(for: template)
            save()
        }
    }

    /// Remove pending occurrences that the user has not engaged with.
    ///
    /// "Untouched" is the important qualifier. An occurrence that is still
    /// open, still carries the template's title, and has no notes or subtask
    /// progress of its own is a placeholder the app put there; anything else is
    /// the user's work and is left alone even when the schedule changes under
    /// it.
    private func discardUntouchedFutureInstances(of template: Todo) {
        for instance in template.recurrenceInstanceList {
            guard !instance.state.isResolved,
                  instance.title == template.title,
                  instance.notes == template.notes,
                  instance.subtaskList.allSatisfy({ !$0.state.isResolved })
            else { continue }
            context.delete(instance)
        }
    }

    /// Skip the occurrence in hand and move the series on to the next one.
    ///
    /// Distinct from completing it: skipping says the work did not happen and
    /// should not be recorded as done, but the schedule should still advance.
    func skipRecurrenceInstance(_ instance: Todo) {
        guard let template = instance.recurrenceTemplate,
              let rule = template.recurrenceRule
        else { return }

        let snapshot = TodoSnapshot(instance)
        let templateID = template.uuid
        let previousNext = template.recurrenceNextDate

        // An `.afterCompletion` series measures from the skip, since that is
        // the moment the user dealt with this occurrence.
        if rule.mode == .afterCompletion {
            template.recurrenceNextDate = rule.nextDate(after: Date())
        }

        context.delete(instance)
        save()
        RecurrenceEngine(context: context).generateInstances(for: template)
        save()

        UndoStack.shared.record(
            UndoableAction(
                name: "Skip",
                revert: { context in
                    let store = TodoStore(context: context)
                    guard let template = TodoQueries.todo(uuid: templateID, in: context) else { return }
                    // Take back whatever the skip generated before putting the
                    // skipped occurrence back, so the series is not left with
                    // two live instances.
                    store.discardUntouchedFutureInstances(of: template)
                    snapshot.reinsert(into: context)
                    if let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) {
                        snapshot.apply(to: live, in: context)
                        live.recurrenceTemplate = template
                    }
                    template.recurrenceNextDate = previousNext
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    guard let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) else { return }
                    store.skipRecurrenceInstance(live)
                }
            )
        )
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

    /// Delete a to-do and everything under it.
    ///
    /// Recorded across the whole subtree, because the cascade delete rule takes
    /// the subtasks too — restoring only the row the user selected would put
    /// back an empty project. Snapshots carry their original `uuid`, so the
    /// parent links between restored rows still resolve.
    func delete(_ todo: Todo) {
        let subtree = [todo] + todo.descendants
        let snapshots = subtree.map(TodoSnapshot.init)

        context.delete(todo)
        save()

        UndoStack.shared.record(
            UndoableAction(
                name: "Delete",
                revert: { context in
                    let store = TodoStore(context: context)
                    // Parents first, so a subtask's `parentID` finds its parent
                    // already back in the store rather than restoring an
                    // orphan.
                    for snapshot in snapshots where snapshot.parentID == nil {
                        snapshot.reinsert(into: context)
                    }
                    for snapshot in snapshots where snapshot.parentID != nil {
                        snapshot.reinsert(into: context)
                    }
                    // A second pass to re-link: a child restored before its
                    // parent in the pass above would have found nothing.
                    for snapshot in snapshots {
                        guard let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) else { continue }
                        snapshot.apply(to: live, in: context)
                    }
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    guard let live = TodoQueries.todo(uuid: snapshots[0].uuid, in: context) else { return }
                    context.delete(live)
                    store.save()
                }
            )
        )
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

/// A state change waiting on the user's answer about its subtasks.
///
/// Shared rather than declared beside each checkbox: the list and the calendar
/// both toggle to-dos, and the question they ask has to be the same question —
/// wording included, which is why the strings live here too.
struct PendingCascade: Identifiable {
    let id = UUID()
    let todo: Todo
    let target: CompletionState
    let blockedCount: Int

    /// The confirmation dialog's title.
    var prompt: String {
        let noun = blockedCount == 1 ? "subtask" : "subtasks"
        let verb = target == .completed ? "completed" : "cancelled"
        return "This to-do has \(blockedCount) unfinished \(noun). Also mark them \(verb)?"
    }

    /// Label for the button that resolves the subtasks along with the parent.
    var confirmLabel: String {
        target == .completed ? "Complete All" : "Cancel All"
    }
}
