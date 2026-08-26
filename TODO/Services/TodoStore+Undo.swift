import Foundation
import SwiftData

/// Recording the actions that undo covers.
///
/// Kept beside `TodoStore` rather than inside it so the mutation API stays a
/// plain list of verbs, and so the snapshot machinery — which is only ever
/// about undo — does not sit in the middle of it.
///
/// ## What gets recorded
///
/// The actions that take a row *off the screen it was on*, or destroy
/// something: scheduling, completing, moving, deleting, duplicating,
/// promoting. After any of these the user is looking at a list that no longer
/// contains what they just acted on, and putting it back by hand means finding
/// it first. Everything else — typing a title, editing notes — leaves the thing
/// in front of the user and is not worth a history entry.
extension TodoStore {

    /// The fields undo has to put back.
    ///
    /// A value rather than a reference to the `Todo`: the whole point is to
    /// hold what the to-do *was*, so it has to survive the change being undone
    /// — and, in the delete case, the object's removal from the store.
    struct TodoSnapshot {
        let uuid: UUID
        let title: String
        let notes: String
        let state: CompletionState
        let bucket: Bucket
        let assignedDate: Date?
        let assignedHasTime: Bool
        let duration: TimeInterval?
        let dueDate: Date?
        let dueHasTime: Bool
        let isProject: Bool
        let colorHex: String?
        let sortIndex: Int
        let resolvedAt: Date?
        let spaceID: UUID?
        let parentID: UUID?
        /// The recurrence schedule, so undoing a change to one puts the whole
        /// rule back rather than leaving a half-edited series.
        ///
        /// `recurrenceRule` is a projection over several columns, so restoring
        /// it restores all of them at once — but `recurrenceNextDate` is not
        /// part of the rule and has to be carried separately, or an undone
        /// pause would resume pointing at the wrong date.
        let recurrenceRule: RecurrenceRule?
        let recurrenceNextDate: Date?
        let recurrenceTemplateID: UUID?

        @MainActor
        init(_ todo: Todo) {
            uuid = todo.uuid
            title = todo.title
            notes = todo.notes
            state = todo.state
            bucket = todo.bucket
            assignedDate = todo.assignedDate
            assignedHasTime = todo.assignedHasTime
            duration = todo.duration
            dueDate = todo.dueDate
            dueHasTime = todo.dueHasTime
            isProject = todo.isProject
            colorHex = todo.colorHex
            sortIndex = todo.sortIndex
            resolvedAt = todo.resolvedAt
            spaceID = todo.space?.uuid
            parentID = todo.parent?.uuid
            recurrenceRule = todo.recurrenceRule
            recurrenceNextDate = todo.recurrenceNextDate
            recurrenceTemplateID = todo.recurrenceTemplate?.uuid
        }

        /// Write these fields back onto a live to-do.
        ///
        /// Deliberately assigns the stored properties directly rather than
        /// going through `update`/`move`: those apply the filing rules, which
        /// is exactly what must not happen here. Undo restores a recorded
        /// state; re-deriving the bucket from the restored dates would be the
        /// app making a fresh decision instead of putting things back.
        @MainActor
        func apply(to todo: Todo, in context: ModelContext) {
            todo.title = title
            todo.notes = notes
            todo.state = state
            todo.bucket = bucket
            todo.assignedDate = assignedDate
            todo.assignedHasTime = assignedHasTime
            todo.duration = duration
            todo.dueDate = dueDate
            todo.dueHasTime = dueHasTime
            todo.isProject = isProject
            todo.colorHex = colorHex
            todo.sortIndex = sortIndex
            todo.resolvedAt = resolvedAt
            todo.space = spaceID.flatMap { TodoQueries.space(uuid: $0, in: context) }
            todo.parent = parentID.flatMap { TodoQueries.todo(uuid: $0, in: context) }
            todo.recurrenceRule = recurrenceRule
            todo.recurrenceNextDate = recurrenceNextDate
            todo.recurrenceTemplate = recurrenceTemplateID
                .flatMap { TodoQueries.todo(uuid: $0, in: context) }
            todo.touch()
        }

        /// Recreate a to-do that was deleted.
        ///
        /// The `uuid` is carried over, so anything else undo restores can still
        /// find this row by identifier — a subtask's parent link, for instance.
        @MainActor
        @discardableResult
        func reinsert(into context: ModelContext) -> Todo {
            let todo = Todo()
            todo.uuid = uuid
            context.insert(todo)
            apply(to: todo, in: context)
            return todo
        }
    }

    // MARK: Recording

    /// Run `mutate` and record how to put `todo` back.
    ///
    /// The common shape: snapshot, change, record. The redo closure re-applies
    /// the *after* snapshot rather than re-running `mutate`, so redo cannot
    /// take a second reading of "now" and land somewhere different from where
    /// the original action did.
    func recordingUndo(
        _ name: String,
        on todo: Todo,
        mutate: () -> Void
    ) {
        let before = TodoSnapshot(todo)
        // The verbs `mutate` calls record on their own when used directly; here
        // they are steps inside one action, so only this recording counts.
        UndoStack.shared.performingSilently(mutate)
        let after = TodoSnapshot(todo)

        UndoStack.shared.record(
            UndoableAction(
                name: name,
                revert: { context in
                    guard let live = TodoQueries.todo(uuid: before.uuid, in: context) else { return }
                    before.apply(to: live, in: context)
                    TodoStore(context: context).save()
                },
                reapply: { context in
                    guard let live = TodoQueries.todo(uuid: after.uuid, in: context) else { return }
                    after.apply(to: live, in: context)
                    TodoStore(context: context).save()
                }
            )
        )
    }

    /// Record an action that changed several to-dos at once — a cascade, or a
    /// delete that took subtasks with it.
    func recordingUndo(
        _ name: String,
        on todos: [Todo],
        mutate: () -> Void
    ) {
        let before = todos.map(TodoSnapshot.init)
        UndoStack.shared.performingSilently(mutate)
        // Re-read after the change: a cascade may have resolved rows that were
        // not in the original list.
        let after = before.compactMap { snapshot in
            TodoQueries.todo(uuid: snapshot.uuid, in: context).map(TodoSnapshot.init)
        }

        UndoStack.shared.record(
            UndoableAction(
                name: name,
                revert: { context in
                    let store = TodoStore(context: context)
                    for snapshot in before {
                        if let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) {
                            snapshot.apply(to: live, in: context)
                        } else {
                            snapshot.reinsert(into: context)
                        }
                    }
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    for snapshot in after {
                        if let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) {
                            snapshot.apply(to: live, in: context)
                        }
                    }
                    store.save()
                }
            )
        )
    }
}
