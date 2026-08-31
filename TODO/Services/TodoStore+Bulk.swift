import Foundation
import SwiftData

/// The verbs the multi-select action bar calls.
///
/// Each one is a *single* undoable action covering every to-do it touched.
/// That is the whole reason this file exists rather than the bar looping over
/// the single-item verbs: completing eight rows and then pressing Cmd+Z eight
/// times to get back is not undo, it is punishment — and the toast, which
/// offers exactly one action, would have been describing only the last row.
///
/// The looping still happens, but inside `recordingUndo`'s silence, so the per
/// item verbs make their changes without each recording an entry of its own.
/// See `UndoStack.performingSilently`.
@MainActor
extension TodoStore {

    /// Every to-do a bulk action really touches: the ones passed in, plus the
    /// descendants that go with them.
    ///
    /// Undo needs all of it. A cascade resolves subtasks the user never
    /// selected, and a delete takes the whole subtree — so a snapshot list
    /// covering only the selection would restore a project whose children had
    /// silently stayed deleted.
    private func affected(_ todos: [Todo]) -> [Todo] {
        var seen = Set<UUID>()
        var result: [Todo] = []
        for todo in todos {
            for item in [todo] + todo.descendants where seen.insert(item.uuid).inserted {
                result.append(item)
            }
        }
        return result
    }

    // MARK: State

    /// Set the same state on every selected to-do.
    ///
    /// Cascades without asking, unlike the single-item path, which raises a
    /// confirmation when subtasks block the change. Asking once per blocked
    /// row would mean a chain of dialogs over one press of Complete, and asking
    /// once for all of them would be a prompt the user could not answer
    /// per-row anyway. Selecting a parent is taken as meaning the parent — and
    /// bulk actions are undoable in one step, which is what makes the
    /// assumption cheap to correct.
    func setState(_ todos: [Todo], to newState: CompletionState) {
        guard !todos.isEmpty else { return }

        // Read before the change, so recurrence can be advanced for exactly
        // the instances that crossed the resolved boundary.
        let wasResolved = todos.map { ($0, $0.state.isResolved) }

        recordingUndo(bulkName(for: newState, count: todos.count), on: affected(todos)) {
            for todo in todos {
                todo.setState(newState, cascadeToSubtasks: true)
            }
            save()
        }

        // Outside the recording: generating the next occurrence of a series is
        // not part of what undo puts back — reopening the instance is what
        // withdraws its successor, and that runs here too.
        for (todo, resolved) in wasResolved {
            advanceRecurrenceAfterBulk(for: todo, wasResolved: resolved, isResolved: newState.isResolved)
        }
    }

    /// Toggle every selected to-do, using the majority state to decide which
    /// way the whole batch goes.
    ///
    /// A mixed selection resolves to "complete them all" rather than flipping
    /// each row independently. One button that does opposite things to
    /// different rows leaves the user unable to predict the result, and the
    /// common intent behind selecting a mixed batch and pressing the checkmark
    /// is to finish what is left.
    func toggleAll(_ todos: [Todo]) {
        guard !todos.isEmpty else { return }
        let allResolved = todos.allSatisfy { $0.state.isResolved }
        setState(todos, to: allResolved ? .open : .completed)
    }

    private func bulkName(for state: CompletionState, count: Int) -> String {
        let verb = switch state {
        case .completed: "Complete"
        case .cancelled: "Cancel"
        case .started: "Start"
        case .open: "Reopen"
        }
        return count == 1 ? verb : "\(verb) \(count) To-Dos"
    }

    /// The same edge rule `setState` applies for one to-do, reused per row.
    ///
    /// Duplicated from the private helper next door rather than exposing it:
    /// what is shared is the *rule* — only an instance crossing the resolved
    /// boundary moves its series — and it is two lines.
    private func advanceRecurrenceAfterBulk(for todo: Todo, wasResolved: Bool, isResolved: Bool) {
        guard todo.isRecurrenceInstance, wasResolved != isResolved else { return }
        let engine = RecurrenceEngine(context: context)
        if isResolved {
            engine.handleResolution(of: todo)
        } else {
            engine.handleReopening(of: todo)
        }
    }

    // MARK: Scheduling

    /// Put every selected to-do on the same day.
    func schedule(_ todos: [Todo], to date: Date?, hasTime: Bool = false) {
        guard !todos.isEmpty else { return }
        recordingUndo(bulkName("Schedule", count: todos.count), on: todos) {
            for todo in todos {
                schedule(todo, to: date, hasTime: hasTime)
            }
            save()
        }
    }

    /// Plan every selected to-do into the same week.
    func schedule(_ todos: [Todo], forWeek week: WeekSchedule, now: Date = Date()) {
        guard !todos.isEmpty else { return }
        recordingUndo(bulkName("Schedule", count: todos.count), on: todos) {
            for todo in todos {
                schedule(todo, forWeek: week, now: now)
            }
            save()
        }
    }

    // MARK: Filing

    /// Move every selected to-do into one space.
    func move(_ todos: [Todo], toSpace space: Space?) {
        guard !todos.isEmpty else { return }
        recordingUndo(bulkName("Move", count: todos.count), on: todos) {
            for todo in todos {
                move(todo, toSpace: space)
            }
            save()
        }
    }

    /// Move every selected to-do under one parent, or out to the top level.
    ///
    /// A to-do already inside the target — or the target itself, if the user
    /// managed to select it — is skipped rather than refused: the rest of the
    /// batch still has somewhere to go, and `adopt` is what knows a move would
    /// make a cycle.
    func move(_ todos: [Todo], toParent parent: Todo?) {
        guard !todos.isEmpty else { return }
        recordingUndo(bulkName("Move", count: todos.count), on: todos) {
            for todo in todos {
                if let parent {
                    guard todo.uuid != parent.uuid else { continue }
                    _ = adopt(todo, asSubtaskOf: parent)
                } else {
                    move(todo, toParent: nil)
                }
            }
            save()
        }
    }

    // MARK: Structure

    /// Copy every selected to-do.
    ///
    /// - Returns: the copies, so the caller can select them — duplicating is
    ///   usually the step before editing what was made.
    @discardableResult
    func duplicate(_ todos: [Todo]) -> [Todo] {
        guard !todos.isEmpty else { return [] }
        var copies: [Todo] = []
        // Recorded against the *originals*: the copies do not exist yet, so
        // there is nothing to snapshot, and undo removes them below.
        let before = todos.map(\.uuid)

        UndoStack.shared.performingSilently {
            copies = todos.map { duplicate($0) }
            save()
        }

        let copied = copies.map(TodoSnapshot.init)
        UndoStack.shared.record(
            UndoableAction(
                name: bulkName("Duplicate", count: todos.count),
                revert: { context in
                    let store = TodoStore(context: context)
                    for snapshot in copied {
                        guard let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) else { continue }
                        context.delete(live)
                    }
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    // Re-copies from the originals rather than reinserting the
                    // snapshots, so a redone duplicate reflects the row as it
                    // stands now — the same thing pressing the button again
                    // would produce.
                    for uuid in before {
                        guard let live = TodoQueries.todo(uuid: uuid, in: context) else { continue }
                        _ = store.duplicate(live)
                    }
                    store.save()
                }
            )
        )
        return copies
    }

    /// Promote every selected to-do to a project, or demote them all.
    func setIsProject(_ todos: [Todo], _ promoted: Bool) {
        guard !todos.isEmpty else { return }
        let name = promoted ? "Make Project" : "Demote to To-Do"
        recordingUndo(bulkName(name, count: todos.count, plural: false), on: todos) {
            for todo in todos {
                setIsProject(todo, promoted)
            }
            save()
        }
    }

    // MARK: Deleting

    /// Delete every selected to-do, and everything under them, as one action.
    func delete(_ todos: [Todo]) {
        guard !todos.isEmpty else { return }

        let snapshots = affected(todos).map(TodoSnapshot.init)
        // Only the roots are handed to `context.delete`; the cascade rule takes
        // their subtrees. Deleting a child that a parent in the same selection
        // is about to take with it would be deleting it twice.
        let roots = topLevel(of: todos)

        UndoStack.shared.performingSilently {
            for todo in roots {
                context.delete(todo)
            }
            save()
        }

        let rootIDs = roots.map(\.uuid)
        UndoStack.shared.record(
            UndoableAction(
                name: bulkName("Delete", count: todos.count),
                revert: { context in
                    let store = TodoStore(context: context)
                    // Parents first, so a subtask's `parentID` finds its parent
                    // already back in the store rather than restoring an
                    // orphan — then a second pass to re-link the rest.
                    for snapshot in snapshots where snapshot.parentID == nil {
                        snapshot.reinsert(into: context)
                    }
                    for snapshot in snapshots where snapshot.parentID != nil {
                        snapshot.reinsert(into: context)
                    }
                    for snapshot in snapshots {
                        guard let live = TodoQueries.todo(uuid: snapshot.uuid, in: context) else { continue }
                        snapshot.apply(to: live, in: context)
                    }
                    store.save()
                },
                reapply: { context in
                    let store = TodoStore(context: context)
                    for uuid in rootIDs {
                        guard let live = TodoQueries.todo(uuid: uuid, in: context) else { continue }
                        context.delete(live)
                    }
                    store.save()
                }
            )
        )
    }

    /// The selection with anything already covered by another member removed.
    ///
    /// Selecting a project and one of its subtasks is two rows to the user but
    /// one subtree to the store, and the actions that cascade have to see it
    /// that way.
    private func topLevel(of todos: [Todo]) -> [Todo] {
        let selected = Set(todos.map(\.uuid))
        return todos.filter { todo in
            var parent = todo.parent
            while let current = parent {
                if selected.contains(current.uuid) { return false }
                parent = current.parent
            }
            return true
        }
    }

    /// "Move" for one row, "Move 4 To-Dos" for several.
    ///
    /// The count is what makes a bulk undo entry readable: "Undo Delete" after
    /// clearing nine rows gives no sense of what is about to come back.
    private func bulkName(_ verb: String, count: Int, plural: Bool = true) -> String {
        guard count > 1 else { return verb }
        return plural ? "\(verb) \(count) To-Dos" : "\(verb) (\(count))"
    }
}
