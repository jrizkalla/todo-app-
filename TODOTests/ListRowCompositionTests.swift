import Testing
import Foundation
import SwiftData
@testable import TODO

/// How a list decides which rows to draw, and in particular the interaction
/// between nesting subtasks and pinning the focused row on screen.
@MainActor
struct ListRowCompositionTests {

    private func makeStore() throws -> TodoStore {
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    // MARK: Nesting

    @Test func ordinaryListsNestSubtasks() {
        #expect(ListRowComposition.nestsSubtasks(destination: .today, isSearching: false))
        #expect(ListRowComposition.nestsSubtasks(destination: .inbox, isSearching: false))
    }

    /// The Logbook lists finished work flat, so a completed subtask is not also
    /// shown underneath its parent.
    @Test func logbookIsFlat() {
        #expect(!ListRowComposition.nestsSubtasks(destination: .logbook, isSearching: false))
    }

    /// Search results are flat: a matching subtask is a result in its own right.
    @Test func searchResultsAreFlat() {
        #expect(!ListRowComposition.nestsSubtasks(destination: .today, isSearching: true))
    }

    @Test func flatListsDrawNoNestedSubtasks() throws {
        let store = try makeStore()
        let parent = store.createTodo(title: "Launch")
        store.addSubtask(to: parent, title: "Book the venue")

        #expect(ListRowComposition.nestedSubtasks(
            of: parent, destination: .today, isSearching: false
        ).count == 1)

        #expect(ListRowComposition.nestedSubtasks(
            of: parent, destination: .logbook, isSearching: false
        ).isEmpty)

        #expect(ListRowComposition.nestedSubtasks(
            of: parent, destination: .today, isSearching: true
        ).isEmpty)
    }

    /// A project in an ordinary list says it has subtasks rather than spilling
    /// them: its contents belong to the project's own list, not to Today.
    @Test func projectsDrawNoNestedSubtasks() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        store.addSubtask(to: project, title: "Book the venue")

        #expect(ListRowComposition.nestedSubtasks(
            of: project, destination: .today, isSearching: false
        ).isEmpty)
        #expect(ListRowComposition.nestedSubtasks(
            of: project, destination: .anytime, isSearching: false
        ).isEmpty)
    }

    /// The pinning rule has to agree with the nesting rule: a project's subtask
    /// is not drawn under it, so it is free to be pinned as a top-level row.
    @Test func projectSubtaskIsNotConsideredAlreadyDrawn() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let subtask = store.addSubtask(to: project, title: "Book the venue")

        #expect(!ListRowComposition.isDrawnAsNestedSubtask(
            subtask, in: [project], destination: .today, isSearching: false
        ))
    }

    // MARK: Focused-row pinning

    /// The reported bug: focusing a subtask drew it a second time as a
    /// top-level row, because pinning the focused row did not notice it was
    /// already on screen nested under its parent.
    @Test func focusingASubtaskDoesNotDuplicateIt() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", assignedDate: Date())
        let subtask = store.addSubtask(to: project, title: "Book the venue")

        let rows = ListRowComposition.rows(
            filtered: [project],
            focused: subtask,
            destination: .today,
            isSearching: false
        )

        #expect(rows.map(\.uuid) == [project.uuid])
    }

    /// A subtask whose parent is *not* on screen is not being drawn nested, so
    /// pinning it is the only thing keeping it visible.
    @Test func focusedSubtaskIsPinnedWhenItsParentIsAbsent() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let subtask = store.addSubtask(to: project, title: "Book the venue")

        let rows = ListRowComposition.rows(
            filtered: [],
            focused: subtask,
            destination: .today,
            isSearching: false
        )

        #expect(rows.map(\.uuid) == [subtask.uuid])
    }

    /// In a flat list nothing is drawn nested, so a focused subtask has to be
    /// pinned even when its parent happens to be on screen.
    @Test func focusedSubtaskIsPinnedInFlatLists() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch")
        let subtask = store.addSubtask(to: project, title: "Book the venue")

        let rows = ListRowComposition.rows(
            filtered: [project],
            focused: subtask,
            destination: .today,
            isSearching: true
        )

        #expect(rows.map(\.uuid) == [project.uuid, subtask.uuid])
    }

    /// The behaviour pinning exists for: a top-level row that has stopped
    /// matching the list stays put while it holds the keyboard.
    @Test func focusedTopLevelRowIsPinnedWhenItStopsMatching() throws {
        let store = try makeStore()
        let shown = store.createTodo(title: "Call plumber", assignedDate: Date())
        let drifted = store.createTodo(title: "Renew passport")

        let rows = ListRowComposition.rows(
            filtered: [shown],
            focused: drifted,
            destination: .today,
            isSearching: false
        )

        #expect(rows.map(\.uuid) == [shown.uuid, drifted.uuid])
    }

    /// A row already in the list is not added twice.
    @Test func focusedRowAlreadyPresentIsNotDuplicated() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Call plumber", assignedDate: Date())

        let rows = ListRowComposition.rows(
            filtered: [todo],
            focused: todo,
            destination: .today,
            isSearching: false
        )

        #expect(rows.map(\.uuid) == [todo.uuid])
    }

    @Test func nothingFocusedLeavesTheListAlone() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Call plumber", assignedDate: Date())

        let rows = ListRowComposition.rows(
            filtered: [todo],
            focused: nil,
            destination: .today,
            isSearching: false
        )

        #expect(rows.map(\.uuid) == [todo.uuid])
    }
}
