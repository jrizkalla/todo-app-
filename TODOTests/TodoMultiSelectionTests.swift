import Testing
import Foundation
import SwiftUI
@testable import TODO

/// What the selection gestures do to the set of picked rows.
///
/// The rules being pinned down here are the ones every list on every platform
/// has and nobody can quite state from memory — what a shift-click extends
/// *from*, what happens when it walks back towards its own anchor, and what a
/// modifier does before anything is selected at all. They are cheap to get
/// subtly wrong and expensive to notice.
struct TodoMultiSelectionTests {

    /// Five rows, in the order they are drawn.
    private let order: [UUID] = (0..<5).map { _ in UUID() }

    // MARK: Plain clicks

    @Test func plainClickSelectsOneRow() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[2], in: order)

        #expect(selection.ids == [order[2]])
        #expect(selection.count == 1)
    }

    /// A plain click replaces rather than adds — otherwise there would be no
    /// way to narrow a selection back down without leaving the mode.
    @Test func plainClickReplacesTheSelection() {
        var selection = TodoMultiSelection()
        selection.apply(.toggle, to: order[0], in: order)
        selection.apply(.toggle, to: order[1], in: order)

        selection.apply(.replace, to: order[3], in: order)

        #expect(selection.ids == [order[3]])
    }

    // MARK: Toggle

    @Test func toggleAddsAndRemovesOneRowAtATime() {
        var selection = TodoMultiSelection()
        selection.apply(.toggle, to: order[1], in: order)
        selection.apply(.toggle, to: order[3], in: order)

        #expect(selection.ids == [order[1], order[3]])

        selection.apply(.toggle, to: order[1], in: order)

        #expect(selection.ids == [order[3]])
    }

    /// The bar appears on the first pick and goes once the last one is
    /// deselected — on macOS, where there is no mode to stay in.
    @Test func selectionGoesInactiveWhenEmptied() {
        var selection = TodoMultiSelection()
        selection.apply(.toggle, to: order[0], in: order)
        #expect(selection.isActive)

        selection.apply(.toggle, to: order[0], in: order)
        #expect(!selection.isActive)
    }

    // MARK: Shift-extension

    @Test func extendSelectsTheRangeFromTheAnchor() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[1], in: order)

        selection.apply(.extend, to: order[3], in: order)

        #expect(selection.ids == [order[1], order[2], order[3]])
    }

    /// Ranges run both ways: shift-clicking *above* the anchor is as ordinary
    /// as clicking below it.
    @Test func extendWorksUpwards() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[3], in: order)

        selection.apply(.extend, to: order[1], in: order)

        #expect(selection.ids == [order[1], order[2], order[3]])
    }

    /// The behaviour this model exists for: a second shift-click re-draws the
    /// range from the same fixed anchor rather than growing what is there. A
    /// union would make the selection grow-only, so walking the range back
    /// towards the anchor could never shrink it.
    @Test func repeatedExtendRedrawsFromTheAnchorRatherThanAccumulating() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[0], in: order)
        selection.apply(.extend, to: order[4], in: order)
        #expect(selection.count == 5)

        selection.apply(.extend, to: order[2], in: order)

        #expect(selection.ids == [order[0], order[1], order[2]])
    }

    /// Rows picked out individually are not part of the range, so re-drawing
    /// it must not sweep them away.
    @Test func extendKeepsRowsPickedIndividuallyOutsideTheRange() {
        var selection = TodoMultiSelection()
        selection.apply(.toggle, to: order[4], in: order)
        selection.apply(.toggle, to: order[0], in: order)
        selection.apply(.extend, to: order[2], in: order)
        #expect(selection.ids == [order[0], order[1], order[2], order[4]])

        // Shrink the range; the individually picked row 4 stays.
        selection.apply(.extend, to: order[1], in: order)

        #expect(selection.ids == [order[0], order[1], order[4]])
    }

    /// Shift-clicking with nothing selected has nowhere to measure from, so it
    /// behaves as a plain pick rather than doing nothing.
    @Test func extendWithNoAnchorSelectsJustThatRow() {
        var selection = TodoMultiSelection()

        selection.apply(.extend, to: order[2], in: order)

        #expect(selection.ids == [order[2]])
        #expect(selection.anchor == order[2])
    }

    /// A Cmd-click moves the anchor, so the next shift-click measures from the
    /// row the user last touched rather than from wherever they began.
    @Test func toggleMovesTheAnchor() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[0], in: order)
        selection.apply(.toggle, to: order[3], in: order)

        selection.apply(.extend, to: order[4], in: order)

        #expect(selection.ids == [order[0], order[3], order[4]])
    }

    // MARK: Mode

    /// iOS's Select button: the bar has to appear before anything is picked,
    /// or there is nowhere to press Done.
    @Test func explicitModeIsActiveWithNothingSelected() {
        var selection = TodoMultiSelection()
        selection.beginExplicit()

        #expect(selection.isActive)
        #expect(selection.count == 0)
    }

    /// Deselecting the last row on iOS leaves the mode on — the user turned it
    /// on and only they turn it off.
    @Test func explicitModeSurvivesAnEmptiedSelection() {
        var selection = TodoMultiSelection()
        selection.beginExplicit()
        selection.apply(.toggle, to: order[0], in: order)
        selection.apply(.toggle, to: order[0], in: order)

        #expect(selection.isActive)
    }

    @Test func clearLeavesTheMode() {
        var selection = TodoMultiSelection()
        selection.beginExplicit()
        selection.apply(.toggle, to: order[0], in: order)

        selection.clear()

        #expect(!selection.isActive)
        #expect(selection.ids.isEmpty)
        #expect(selection.anchor == nil)
    }

    @Test func selectAllTakesEveryVisibleRow() {
        var selection = TodoMultiSelection()
        selection.selectAll(in: order)

        #expect(selection.ids == Set(order))
    }

    // MARK: Reconciling

    /// Completing a batch in Today filters every one of them out; the count on
    /// the bar must not go on naming rows that are gone.
    @Test func reconcileDropsRowsThatLeftTheList() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[0], in: order)
        selection.apply(.extend, to: order[2], in: order)

        selection.reconcile(with: [order[0], order[3], order[4]])

        #expect(selection.ids == [order[0]])
    }

    /// An anchor pointing at a row that has gone would measure the next range
    /// from nowhere.
    @Test func reconcileDropsAnAnchorThatLeft() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[1], in: order)

        selection.reconcile(with: [order[0], order[2]])

        #expect(selection.anchor == nil)
        #expect(selection.ids.isEmpty)
    }

    /// A row leaving must not take the *previous range* bookkeeping with it in
    /// a way that makes the next extension misbehave.
    @Test func extendStillWorksAfterReconcile() {
        var selection = TodoMultiSelection()
        selection.apply(.replace, to: order[0], in: order)
        selection.apply(.extend, to: order[1], in: order)

        // Row 1 leaves; the anchor at row 0 survives.
        let remaining = [order[0], order[2], order[3], order[4]]
        selection.reconcile(with: remaining)
        #expect(selection.ids == [order[0]])

        selection.apply(.extend, to: order[3], in: remaining)

        #expect(selection.ids == [order[0], order[2], order[3]])
    }
}

/// What a click on a row means, given the modifier keys and the platform mode.
///
/// This is the macOS half of the feature stated as a rule rather than as three
/// gesture recognizers. The recognizers themselves belong to SwiftUI and only
/// fire on a real click — but which of them *should* win, and what an
/// unmodified click still has to do, is this app's decision and is exactly
/// what a regression would break silently.
struct RowClickIntentTests {

    /// The case that matters most: nothing about an ordinary click changed.
    /// Multi-select is additive, and a plain click still expands the row.
    @Test func aPlainClickIsUnchanged() {
        #expect(RowClickIntent.resolve(modifiers: [], isSelecting: false) == .plain)
    }

    @Test func commandClickToggles() {
        #expect(RowClickIntent.resolve(modifiers: .command, isSelecting: false) == .toggle)
    }

    @Test func shiftClickExtends() {
        #expect(RowClickIntent.resolve(modifiers: .shift, isSelecting: false) == .extend)
    }

    /// Shift wins over Command, which is what every Mac list does.
    @Test func shiftBeatsCommandWhenBothAreDown() {
        #expect(RowClickIntent.resolve(modifiers: [.shift, .command], isSelecting: false) == .extend)
    }

    /// iOS's Select mode turns an unmodified tap into a toggle — the phone's
    /// substitute for having a Command key.
    @Test func anUnmodifiedTapTogglesInsideSelectMode() {
        #expect(RowClickIntent.resolve(modifiers: [], isSelecting: true) == .toggle)
    }

    /// Modifiers still win inside the mode, so a Mac running in a mode-like
    /// state — or an iPad with a keyboard — does not lose shift-ranges.
    @Test func shiftStillExtendsInsideSelectMode() {
        #expect(RowClickIntent.resolve(modifiers: .shift, isSelecting: true) == .extend)
    }

    /// Modifiers the app does not claim are not selection gestures; an
    /// Option-click must not silently behave like a Command-click.
    @Test func unclaimedModifiersFallThroughToAPlainClick() {
        #expect(RowClickIntent.resolve(modifiers: .option, isSelecting: false) == .plain)
        #expect(RowClickIntent.resolve(modifiers: .control, isSelecting: false) == .plain)
    }
}
