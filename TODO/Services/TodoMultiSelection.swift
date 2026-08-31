import Foundation
import Observation

/// Which rows the user has picked out to act on together, and what the
/// platform's selection gestures do to that set.
///
/// Deliberately free of SwiftUI and of `Todo`, for the same reasons as
/// `KeyboardCursor` beside it: it works on ids alone, so the list and anything
/// else that grows a multi-select can share it, and the rules — which are the
/// fiddly part — can be tested without building a view.
///
/// ## The anchor
///
/// A shift-click does not extend from *the last row clicked* but from an
/// anchor, which only a plain click or a Cmd-click moves. That is what makes
/// repeated shift-clicks re-draw the same range from one fixed end rather than
/// growing it a row at a time: shift-clicking row 5 then row 3 selects 3...5,
/// not 3...5 plus 5...3. Every platform's list behaves this way, and getting
/// it wrong is the thing people notice without being able to name.
struct TodoMultiSelection: Equatable {
    /// The picked rows. Unordered — the list draws them in its own order, and
    /// the actions apply to all of them at once.
    private(set) var ids: Set<UUID> = []

    /// Where a shift-extension measures from. See the note above.
    private(set) var anchor: UUID?

    /// The rows the last shift-extension covered, so the next one can replace
    /// its range rather than accumulate. See `apply(_:to:in:)`.
    private var extent: Set<UUID> = []

    /// Whether the user has explicitly asked for multi-select.
    ///
    /// iOS only in practice: there are no modifier keys on a phone, so the
    /// mode is entered from the toolbar and every tap then toggles a row. On
    /// macOS the modifiers say what the user meant, so the mode is implied by
    /// the set being non-empty and this stays false.
    private(set) var isExplicit = false

    init() {}

    /// True when the bar at the bottom should be on screen.
    ///
    /// Either at least one row is picked, or the user has turned the mode on
    /// and has not picked anything yet — the second case is what gives them
    /// somewhere to press Done.
    var isActive: Bool { !ids.isEmpty || isExplicit }

    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    // MARK: Gestures

    /// How a click or tap on a row was modified.
    enum Gesture {
        /// A plain click: this row alone becomes the selection.
        case replace
        /// Cmd-click, or any tap while iOS's explicit mode is on: add or
        /// remove this one row, leaving the rest alone.
        case toggle
        /// Shift-click: select everything between the anchor and this row.
        case extend
    }

    /// Apply a click on `id`, given the rows currently on screen in draw order.
    ///
    /// `order` is what a range means: "between" is a question about what the
    /// user can see, so the rows are taken as drawn rather than by any
    /// underlying sort.
    mutating func apply(_ gesture: Gesture, to id: UUID, in order: [UUID]) {
        switch gesture {
        case .replace:
            ids = [id]
            anchor = id

        case .toggle:
            if ids.contains(id) {
                ids.remove(id)
                // The anchor cannot stay on a row that is no longer picked, or
                // a following shift-click would measure from a gap. The row
                // just deselected is still where the user's attention is, so
                // the next range starts there.
                if anchor == id { anchor = ids.isEmpty ? nil : id }
            } else {
                ids.insert(id)
                anchor = id
            }

        case .extend:
            // With nowhere to measure from, a shift-click is just a click.
            // This is the first-interaction case: the user shift-clicked
            // before selecting anything at all.
            guard let anchor, anchor != id,
                  let start = order.firstIndex(of: anchor),
                  let end = order.firstIndex(of: id)
            else {
                ids.insert(id)
                if self.anchor == nil { self.anchor = id }
                return
            }

            let range = start <= end ? start...end : end...start
            // Replaces the range rather than adding to it. A shift-click is
            // "select from the anchor to here", so walking the selection back
            // up towards the anchor has to *shrink* it — union would make the
            // range grow-only and leave rows picked that are no longer between
            // the two ends.
            //
            // Rows picked by Cmd-click outside the range survive: those were
            // chosen individually and are not part of what this range
            // describes. Only the previous range is replaced.
            let previousRange = previousExtent(in: order)
            ids.subtract(previousRange)
            ids.formUnion(order[range])
            extent = Set(order[range])
        }
    }

    /// The previous range, minus the anchor.
    private func previousExtent(in order: [UUID]) -> Set<UUID> {
        // The anchor is never dropped by an extension: it is the fixed end of
        // both the old range and the new one, so removing it here would clear
        // it out from under a range that is about to put it straight back.
        var previous = extent
        if let anchor { previous.remove(anchor) }
        return previous
    }

    // MARK: Mode

    /// Turn the explicit mode on — iOS's "Select" button.
    mutating func beginExplicit() {
        isExplicit = true
    }

    /// Put everything down: clears the set, the anchor and the mode.
    mutating func clear() {
        ids = []
        anchor = nil
        extent = []
        isExplicit = false
    }

    /// Select every row on screen.
    mutating func selectAll(in order: [UUID]) {
        ids = Set(order)
        anchor = order.first
        extent = []
    }

    /// Drop ids naming rows that are no longer on screen.
    ///
    /// Called when the visible set changes — completing a batch of to-dos in
    /// Today filters them all out, and a selection left pointing at rows that
    /// are gone would have the action bar reporting a count the user cannot
    /// see. The mode itself survives: on iOS the user turned it on and only
    /// they should turn it off.
    mutating func reconcile(with order: [UUID]) {
        guard !ids.isEmpty else { return }
        let visible = Set(order)
        ids.formIntersection(visible)
        extent.formIntersection(visible)
        // An anchor naming a row that has gone would measure the next range
        // from nowhere, so it is dropped rather than guessed at.
        if let anchor, !visible.contains(anchor) { self.anchor = nil }
    }
}

/// Whether *some* list on screen is in multi-select, for the parts of the app
/// that are not the list.
///
/// Only one thing reads it: the app-wide create button, which floats over the
/// bottom-right corner the action bar occupies and would otherwise cover the
/// bar's own controls. The button lives in `RootView`, several layers above
/// whichever list owns the selection, and there is no binding between them —
/// so this is the narrow channel between the two rather than a second copy of
/// the selection.
///
/// Withdrawing the button is right for its own sake as well as for the layout:
/// "new to-do" is not an action on a selection, and a list mid-batch is not
/// where someone is about to start typing a new row.
@MainActor
@Observable
final class MultiSelectPresence {
    static let shared = MultiSelectPresence()

    private(set) var isActive = false

    private init() {}

    /// Called by the list as its selection comes and goes.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
    }
}
