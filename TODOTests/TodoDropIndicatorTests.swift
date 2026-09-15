import Testing
import Foundation
import SwiftData
@testable import TODO

/// Where the macOS drop line goes, and what a drop at that position does.
///
/// The drag session itself cannot be driven from a test, so these cover the
/// arithmetic underneath it: which gap a point is nearest, and what the list
/// looks like afterwards.
@MainActor
struct TodoDropIndicatorTests {

    private func makeStore() throws -> TodoStore {
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    /// Three 20pt rows stacked from y=0, with no gaps between them.
    private var threeRows: [ClosedRange<CGFloat>] {
        [0...20, 20...40, 40...60]
    }

    // MARK: Where the line goes

    /// Above the midpoint of the first row means "before everything".
    @Test func aPointInTheTopHalfOfTheFirstRowInsertsAboveIt() {
        #expect(TodoDropIndicator.insertionIndex(for: 4, in: threeRows) == 0)
    }

    /// Past a row's midpoint the line moves to its far side, so it tracks the
    /// pointer continuously rather than jumping only at row boundaries.
    @Test func theLineCrossesAtEachRowsMidpoint() {
        #expect(TodoDropIndicator.insertionIndex(for: 9, in: threeRows) == 0)
        #expect(TodoDropIndicator.insertionIndex(for: 11, in: threeRows) == 1)
        #expect(TodoDropIndicator.insertionIndex(for: 29, in: threeRows) == 1)
        #expect(TodoDropIndicator.insertionIndex(for: 31, in: threeRows) == 2)
    }

    /// Below the last row means "after everything", which is how a row is
    /// dragged to the end of a list.
    @Test func aPointBelowEveryRowInsertsAtTheEnd() {
        #expect(TodoDropIndicator.insertionIndex(for: 500, in: threeRows) == 3)
    }

    /// A point above the list entirely still resolves, rather than trapping.
    @Test func aPointAboveEveryRowInsertsAtTheStart() {
        #expect(TodoDropIndicator.insertionIndex(for: -50, in: threeRows) == 0)
    }

    /// An empty list has exactly one gap, and no rows to compare against.
    @Test func anEmptyListHasASingleGap() {
        #expect(TodoDropIndicator.insertionIndex(for: 17, in: []) == 0)
    }

    /// Rows separated by padding leave dead space between them; a point there
    /// belongs to the gap it sits in rather than to either neighbour.
    @Test func aPointInThePaddingBetweenRowsPicksThatGap() {
        let spaced: [ClosedRange<CGFloat>] = [0...20, 30...50]
        #expect(TodoDropIndicator.insertionIndex(for: 25, in: spaced) == 1)
    }

    // MARK: What the drop does

    /// The ordinary case: a row dragged upwards lands where the line was.
    @Test func aRowMovesUpToTheGapItWasDroppedOn() throws {
        let store = try makeStore()
        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")
        let c = store.createTodo(title: "C")

        let reordered = try #require(
            TodoDropIndicator.reordering([a, b, c], moving: c, to: 0)
        )
        #expect(reordered.map(\.title) == ["C", "A", "B"])
    }

    /// Dragging downwards is where the off-by-one lives: the gap was measured
    /// against a list that still contained the row, so removing it first shifts
    /// every later gap up by one.
    @Test func aRowMovesDownToTheGapItWasDroppedOn() throws {
        let store = try makeStore()
        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")
        let c = store.createTodo(title: "C")

        // Gap 3 is below every row, so A should end up last — not second.
        let reordered = try #require(
            TodoDropIndicator.reordering([a, b, c], moving: a, to: 3)
        )
        #expect(reordered.map(\.title) == ["B", "C", "A"])
    }

    /// Dropping into either gap touching the row's own home is a no-op, and
    /// says so, so the caller can skip the write and the undo entry.
    @Test func droppingWhereItAlreadyIsChangesNothing() throws {
        let store = try makeStore()
        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")
        let c = store.createTodo(title: "C")

        // B occupies index 1, so gaps 1 and 2 both leave it between A and C.
        #expect(TodoDropIndicator.reordering([a, b, c], moving: b, to: 1) == nil)
        #expect(TodoDropIndicator.reordering([a, b, c], moving: b, to: 2) == nil)
    }

    /// A to-do that is not in the list cannot be positioned within it.
    @Test func aRowFromAnotherListIsRefused() throws {
        let store = try makeStore()
        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")
        let stranger = store.createTodo(title: "Elsewhere")

        #expect(TodoDropIndicator.reordering([a, b], moving: stranger, to: 1) == nil)
    }

    /// An index past the end is clamped rather than trapping — a pointer below
    /// the list reports a large y, and the arithmetic has to survive it.
    @Test func anOutOfRangeIndexIsClamped() throws {
        let store = try makeStore()
        let a = store.createTodo(title: "A")
        let b = store.createTodo(title: "B")

        let reordered = try #require(
            TodoDropIndicator.reordering([a, b], moving: a, to: 99)
        )
        #expect(reordered.map(\.title) == ["B", "A"])
    }

    /// Every row keeps its identity through a move: reordering rearranges the
    /// list, it does not duplicate or drop anything.
    @Test func reorderingPreservesEveryRow() throws {
        let store = try makeStore()
        let todos = (1...5).map { store.createTodo(title: "\($0)") }

        let reordered = try #require(
            TodoDropIndicator.reordering(todos, moving: todos[1], to: 4)
        )
        #expect(reordered.count == todos.count)
        #expect(Set(reordered.map(\.uuid)) == Set(todos.map(\.uuid)))
    }

    // MARK: Where the line is allowed at all

    /// A list with an order of its own can show a position.
    @Test func anOrderedListShowsTheLine() {
        #expect(TodoDropIndicator.showsLine(for: .today, isSearching: false))
        #expect(TodoDropIndicator.showsLine(for: .inbox, isSearching: false))
        #expect(TodoDropIndicator.showsLine(for: .anytime, isSearching: false))
    }

    /// Search results are ranked and drawn from several lists, so a position
    /// among them describes nothing worth saving — the same reason `onMove`
    /// already refuses to reorder while searching.
    @Test func searchResultsShowNoLine() {
        #expect(!TodoDropIndicator.showsLine(for: .today, isSearching: true))
    }

    /// The Logbook refuses drops outright, so promising a position there would
    /// be a line that never delivers.
    @Test func theLogbookShowsNoLine() {
        #expect(!TodoDropIndicator.showsLine(for: .logbook, isSearching: false))
    }
}
