import Testing
import Foundation
@testable import TODO

/// Arrow-key movement rules, tested without building a view.
struct KeyboardCursorTests {

    private let items = (0..<4).map { _ in UUID() }

    // MARK: Starting from nothing

    /// Down with no selection takes the first row, which is what makes the
    /// arrows usable without clicking first.
    @Test func downFromEmptySelectsFirst() {
        var cursor = KeyboardCursor()
        let moved = cursor.move(.down, in: items)
        #expect(moved)
        #expect(cursor.selection == items.first)
    }

    @Test func upFromEmptySelectsLast() {
        var cursor = KeyboardCursor()
        let moved = cursor.move(.up, in: items)
        #expect(moved)
        #expect(cursor.selection == items.last)
    }

    @Test func movingInAnEmptyListDoesNothing() {
        var cursor = KeyboardCursor()
        let moved = cursor.move(.down, in: [])
        #expect(moved == false)
        #expect(cursor.selection == nil)
    }

    // MARK: Stepping

    @Test func downStepsForward() {
        var cursor = KeyboardCursor(selection: items[1])
        let moved = cursor.move(.down, in: items)
        #expect(moved)
        #expect(cursor.selection == items[2])
    }

    @Test func upStepsBackward() {
        var cursor = KeyboardCursor(selection: items[2])
        let moved = cursor.move(.up, in: items)
        #expect(moved)
        #expect(cursor.selection == items[1])
    }

    /// The cursor stops at the ends rather than wrapping — wrapping would jump
    /// the user from the top of a list to something weeks away.
    @Test func stopsAtTheBottom() {
        var cursor = KeyboardCursor(selection: items.last)
        let moved = cursor.move(.down, in: items)
        #expect(moved == false)
        #expect(cursor.selection == items.last)
    }

    @Test func stopsAtTheTop() {
        var cursor = KeyboardCursor(selection: items.first)
        let moved = cursor.move(.up, in: items)
        #expect(moved == false)
        #expect(cursor.selection == items.first)
    }

    /// A selection naming something not in the list restarts from the end the
    /// key points at.
    @Test func staleSelectionRestarts() {
        var cursor = KeyboardCursor(selection: UUID())
        let moved = cursor.move(.down, in: items)
        #expect(moved)
        #expect(cursor.selection == items.first)
    }

    // MARK: Reconciling after the list changes

    /// A row vanishing — completed, or filtered out — hands the cursor to the
    /// row that took its place.
    @Test func vanishedRowFallsToSuccessor() {
        var cursor = KeyboardCursor(selection: items[1])
        let after = [items[0], items[2], items[3]]

        cursor.reconcile(with: after, previousOrder: items)
        #expect(cursor.selection == items[2])
    }

    /// With nothing after it, the cursor falls back to the row before.
    @Test func vanishedLastRowFallsToPredecessor() {
        var cursor = KeyboardCursor(selection: items[3])
        let after = Array(items[0..<3])

        cursor.reconcile(with: after, previousOrder: items)
        #expect(cursor.selection == items[2])
    }

    /// Everything going away clears the cursor rather than leaving it dangling.
    @Test func emptyingTheListClearsTheCursor() {
        var cursor = KeyboardCursor(selection: items[1])
        cursor.reconcile(with: [], previousOrder: items)
        #expect(cursor.selection == nil)
    }

    /// A selection that survives is left exactly where it was.
    @Test func survivingSelectionIsUntouched() {
        var cursor = KeyboardCursor(selection: items[1])
        cursor.reconcile(with: items, previousOrder: items)
        #expect(cursor.selection == items[1])
    }

    @Test func reconcilingWithNoSelectionDoesNothing() {
        var cursor = KeyboardCursor()
        cursor.reconcile(with: items, previousOrder: items)
        #expect(cursor.selection == nil)
    }

    // MARK: Explicit selection

    @Test func selectOverridesTheCursor() {
        var cursor = KeyboardCursor(selection: items[0])
        cursor.select(items[2])
        #expect(cursor.selection == items[2])
    }

    @Test func selectNilClears() {
        var cursor = KeyboardCursor(selection: items[0])
        cursor.select(nil)
        #expect(cursor.selection == nil)
    }

    // MARK: Commands

    /// Every command has a distinct notification, or two shortcuts would
    /// trigger each other.
    @Test func commandNotificationNamesAreUnique() {
        let names = Set(KeyboardCommand.allCases.map(\.notificationName))
        #expect(names.count == KeyboardCommand.allCases.count)
    }

    @Test func everyCommandHasAMenuTitle() {
        #expect(KeyboardCommand.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
