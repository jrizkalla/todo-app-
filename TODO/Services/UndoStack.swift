import Foundation
import Observation
import SwiftData

/// One reversible action, with everything needed to put the store back.
///
/// Actions are recorded as *closures over identifiers*, not over model objects.
/// A `Todo` fetched now may be a different instance — or gone — by the time the
/// user undoes, and holding the object would keep a deleted model alive and
/// undo against a context that no longer owns it. Looking the to-do up by
/// `uuid` at undo time is what makes the operation safe to defer.
struct UndoableAction {
    /// Shown in the toast and in the Edit menu: "Undo Complete", "Undo Move".
    let name: String

    /// Put the store back the way it was. Runs on the main actor.
    fileprivate let revert: @MainActor (ModelContext) -> Void

    /// Redo the action after an undo, so Cmd+Shift+Z is symmetric.
    fileprivate let reapply: @MainActor (ModelContext) -> Void

    init(
        name: String,
        revert: @escaping @MainActor (ModelContext) -> Void,
        reapply: @escaping @MainActor (ModelContext) -> Void
    ) {
        self.name = name
        self.revert = revert
        self.reapply = reapply
    }
}

/// The app's undo history for actions that are hard to reverse by hand.
///
/// Deliberately *not* SwiftData's own `UndoManager`. That one registers every
/// change made to the context, which here includes bookkeeping the user never
/// performed — clearing "new" dots on arriving at a list, refiling a to-do's
/// bucket after an edit, marking rows viewed. Undo would then step back through
/// invisible changes, and the first Cmd+Z after opening a list would appear to
/// do nothing at all.
///
/// What is recorded instead is the small set of actions the user would struggle
/// to reverse themselves: the ones that make a row *leave the list it was on*,
/// or destroy something. Scheduling a to-do out of Today, completing it,
/// moving it to another space, and deleting it all qualify — after any of them
/// the row is gone from the screen the user was looking at, and finding it
/// again to put it back is the work undo exists to save.
///
/// Edits the user can see and retype — typing in a title, toggling a setting —
/// are not recorded: the field is still in front of them.
@MainActor
@Observable
final class UndoStack {
    static let shared = UndoStack()

    /// How much history is kept. Deep enough to walk back out of a wrong turn,
    /// shallow enough that it never becomes a second, invisible database.
    static let limit = 25

    private(set) var undoable: [UndoableAction] = []
    private(set) var redoable: [UndoableAction] = []

    /// The action a toast is currently offering to undo, if any.
    ///
    /// Separate from the stack: the toast shows only the *latest* action and
    /// disappears on its own, while the stack is what Cmd+Z walks. Cleared when
    /// the toast times out, is dismissed, or is acted on.
    private(set) var toast: UndoableAction?

    /// Bumped whenever a new action arrives, so the toast's dismissal timer can
    /// tell "still the same action" from "a new one replaced it".
    private(set) var toastGeneration = 0

    var canUndo: Bool { !undoable.isEmpty }
    var canRedo: Bool { !redoable.isEmpty }

    /// The name of what Cmd+Z would undo, for the Edit menu.
    var undoActionName: String? { undoable.last?.name }
    var redoActionName: String? { redoable.last?.name }

    private init() {}

    /// True while an undo or redo is being applied.
    ///
    /// Reverting runs the same `TodoStore` verbs the user does, and those
    /// record undo entries of their own. Without this the stack would grow a
    /// new entry every time it was walked, and redo would push a duplicate of
    /// the action it just replayed.
    private(set) var isReplaying = false

    /// Record an action the user just performed.
    ///
    /// Recording clears the redo stack, the usual rule: once the user does
    /// something new, the branch they had undone is no longer reachable.
    ///
    /// Ignored entirely during a replay — see `isReplaying`.
    func record(_ action: UndoableAction) {
        guard !isReplaying else { return }

        undoable.append(action)
        if undoable.count > Self.limit { undoable.removeFirst() }
        redoable.removeAll()

        toast = action
        toastGeneration += 1
    }

    /// Run a revert or reapply with recording suppressed.
    private func replaying(_ body: () -> Void) {
        isReplaying = true
        defer { isReplaying = false }
        body()
    }

    /// Run `body` with recording suppressed.
    ///
    /// What makes a compound action one entry: the outer recording snapshots
    /// the before and after, and the store verbs it calls in between — each of
    /// which records on its own when used directly — stay quiet. Without this,
    /// one drop onto the Inbox would leave three entries on the stack and take
    /// three Cmd+Zs to walk back.
    func performingSilently<T>(_ body: () -> T) -> T {
        let wasReplaying = isReplaying
        isReplaying = true
        defer { isReplaying = wasReplaying }
        return body()
    }

    @discardableResult
    func undo(in context: ModelContext) -> UndoableAction? {
        guard let action = undoable.popLast() else { return nil }

        replaying { action.revert(context) }
        redoable.append(action)
        // The toast offers one undo; taking it leaves nothing to offer.
        dismissToast()
        return action
    }

    @discardableResult
    func redo(in context: ModelContext) -> UndoableAction? {
        guard let action = redoable.popLast() else { return nil }

        replaying { action.reapply(context) }
        undoable.append(action)
        return action
    }

    func dismissToast() {
        toast = nil
    }

    /// Drop the toast only if it is still showing the action it was raised for.
    ///
    /// The timer that calls this is started per action; without the generation
    /// check, an earlier action's timer would dismiss a newer action's toast
    /// partway through its own display.
    func dismissToast(ifGeneration generation: Int) {
        guard toastGeneration == generation else { return }
        toast = nil
    }

    /// Forget everything. Used when the store underneath changes — an import
    /// replaces the database, so actions recorded against the old one would
    /// undo into rows that no longer exist.
    func reset() {
        undoable.removeAll()
        redoable.removeAll()
        toast = nil
    }
}
