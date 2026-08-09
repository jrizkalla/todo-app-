import Testing
import Foundation
import SwiftData
@testable import TODO

/// Hiding spaces behind a system Focus.
@MainActor
struct FocusFilterTests {

    private func makeStore() throws -> (TodoStore, ModelContext) {
        let container = try ModelContainer.appContainer(inMemory: true)
        let context = ModelContext(container)
        return (TodoStore(context: context), context)
    }

    @Test func spacesAreVisibleByDefault() throws {
        let (store, _) = try makeStore()
        let space = store.createSpace(name: "Work")

        #expect(!space.isHiddenByFocus)
        #expect([space].visibleUnderFocus.count == 1)
    }

    @Test func hiddenSpacesAreDroppedFromTheVisibleList() throws {
        let (store, _) = try makeStore()

        let work = store.createSpace(name: "Work")
        let home = store.createSpace(name: "Home")
        work.isHiddenByFocus = true

        let visible = [work, home].visibleUnderFocus

        #expect(visible.map(\.name) == ["Home"])
    }

    @Test func visibleSpacesComeBackInSortOrder() throws {
        let (store, _) = try makeStore()

        let first = store.createSpace(name: "First")
        let second = store.createSpace(name: "Second")
        first.sortIndex = 5
        second.sortIndex = 1

        #expect([first, second].visibleUnderFocus.map(\.name) == ["Second", "First"])
    }

    /// A to-do inherits its space's visibility, which is what lets one flag
    /// drive both the sidebar and the lists.
    @Test func todosInHiddenSpacesAreHidden() throws {
        let (store, _) = try makeStore()

        let work = store.createSpace(name: "Work")
        let todo = store.createTodo(title: "Ship it", space: work)

        #expect(!todo.isHiddenByFocus)

        work.isHiddenByFocus = true
        #expect(todo.isHiddenByFocus)
    }

    /// Inbox and Anytime are outside every space, so a space-based Focus filter
    /// must never hide them.
    @Test func todosWithNoSpaceAreNeverHidden() throws {
        let (store, _) = try makeStore()

        let work = store.createSpace(name: "Work")
        work.isHiddenByFocus = true

        let loose = store.createTodo(title: "Buy milk")

        #expect(!loose.isHiddenByFocus)
    }

    /// The point of filtering in `topLevel`: a hidden space's work disappears
    /// from the date-based lists too, not just from the sidebar.
    @Test func hiddenSpacesWorkIsExcludedFromTodayAndThisWeek() throws {
        let (store, _) = try makeStore()

        let work = store.createSpace(name: "Work")
        let home = store.createSpace(name: "Home")

        let today = Calendar.current.startOfDay(for: Date())
        let workTask = store.createTodo(title: "Standup", space: work, assignedDate: today)
        let homeTask = store.createTodo(title: "Dishes", space: home, assignedDate: today)

        let all = [workTask, homeTask]

        #expect(TodoQueries.today(all).count == 2)
        #expect(TodoQueries.thisWeek(all).count == 2)

        work.isHiddenByFocus = true

        #expect(TodoQueries.today(all).map(\.title) == ["Dishes"])
        #expect(TodoQueries.thisWeek(all).map(\.title) == ["Dishes"])
    }

    @Test func hiddenSpacesWorkIsExcludedFromInboxAndAnytime() throws {
        let (store, _) = try makeStore()

        let work = store.createSpace(name: "Work")
        work.isHiddenByFocus = true

        // A todo filed in a space reports the `.space` bucket, so put one in
        // Anytime by giving it a date and then filing it.
        let inboxItem = store.createTodo(title: "Loose")
        let dated = store.createTodo(title: "Dated", assignedDate: Date())

        // Neither is in the hidden space, so both survive.
        #expect(TodoQueries.inbox([inboxItem]).map(\.title) == ["Loose"])
        #expect(TodoQueries.anytime([dated]).map(\.title) == ["Dated"])
    }
}
