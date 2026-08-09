import Testing
import Foundation
import SwiftData
@testable import TODO

/// Text search, and the way each surface scopes it.
@MainActor
struct TodoSearchTests {

    private func makeStore() throws -> TodoStore {
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    // MARK: Activation

    @Test func blankQueriesAreNotSearches() throws {
        #expect(!TodoSearch.isActive(""))
        #expect(!TodoSearch.isActive("   "))
        #expect(!TodoSearch.isActive("\n\t"))
        #expect(TodoSearch.isActive("a"))
    }

    /// The list should be left alone until there is something to match, so a
    /// whitespace-only query returns nothing rather than everything.
    @Test func blankQueriesMatchNothing() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Buy milk")

        #expect(TodoSearch.matches([todo], query: "  ").isEmpty)
    }

    // MARK: Matching

    @Test func matchesAreCaseInsensitive() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Buy Milk")

        #expect(TodoSearch.matches([todo], query: "milk").count == 1)
        #expect(TodoSearch.matches([todo], query: "MILK").count == 1)
    }

    @Test func matchesIgnoreAccents() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Update résumé")

        #expect(TodoSearch.matches([todo], query: "resume").count == 1)
    }

    /// Notes carry the detail a to-do is often only findable by.
    @Test func notesAreSearchable() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Call the bank", notes: "Account 4471")

        #expect(TodoSearch.matches([todo], query: "4471").count == 1)
    }

    @Test func spaceAndProjectNamesAreSearchable() throws {
        let store = try makeStore()
        let work = store.createSpace(name: "Work")
        let project = store.createTodo(title: "Launch", space: work, isProject: true)
        let task = store.createTodo(title: "Draft copy", space: work, parent: project)

        #expect(TodoSearch.matches([task], query: "work").map(\.title) == ["Draft copy"])
        #expect(TodoSearch.matches([task], query: "launch").map(\.title) == ["Draft copy"])
    }

    /// Terms are AND-ed and order-independent, so typing more narrows.
    @Test func allTermsMustMatchInAnyOrder() throws {
        let store = try makeStore()
        let milk = store.createTodo(title: "Buy milk")
        let bread = store.createTodo(title: "Buy bread")
        let all = [milk, bread]

        #expect(TodoSearch.matches(all, query: "buy").count == 2)
        #expect(TodoSearch.matches(all, query: "buy milk").map(\.title) == ["Buy milk"])
        #expect(TodoSearch.matches(all, query: "milk buy").map(\.title) == ["Buy milk"])
        #expect(TodoSearch.matches(all, query: "buy eggs").isEmpty)
    }

    /// A title match outranks a notes-only match.
    @Test func titleMatchesSortAboveNotesMatches() throws {
        let store = try makeStore()
        let mentioned = store.createTodo(title: "Weekly review", notes: "Remember the invoice")
        let titled = store.createTodo(title: "Invoice Acme")

        let results = TodoSearch.matches([mentioned, titled], query: "invoice")

        #expect(results.map(\.title) == ["Invoice Acme", "Weekly review"])
    }

    // MARK: Scope

    @Test func unresolvedScopeExcludesFinishedWork() throws {
        let store = try makeStore()
        let open = store.createTodo(title: "Ship it")
        let done = store.createTodo(title: "Ship the beta")
        let cancelled = store.createTodo(title: "Ship the alpha")
        done.setState(.completed)
        cancelled.setState(.cancelled)

        let results = TodoSearch.matches([open, done, cancelled], query: "ship")

        #expect(results.map(\.title) == ["Ship it"])
    }

    @Test func resolvedScopeReturnsOnlyFinishedWork() throws {
        let store = try makeStore()
        let open = store.createTodo(title: "Ship it")
        let done = store.createTodo(title: "Ship the beta")
        done.setState(.completed)

        let results = TodoSearch.matches([open, done], query: "ship", scope: .resolved)

        #expect(results.map(\.title) == ["Ship the beta"])
    }

    /// Cancelled work is history too, so the Logbook's search finds it.
    @Test func resolvedScopeIncludesCancelledWork() throws {
        let store = try makeStore()
        let cancelled = store.createTodo(title: "Ship the alpha")
        cancelled.setState(.cancelled)

        #expect(TodoSearch.matches([cancelled], query: "ship", scope: .resolved).count == 1)
    }

    /// The whole point of the Logbook's field behaving differently.
    ///
    /// The fixtures are dated so they are members of Today as well as of the
    /// Logbook — the scope, not the pool, is what this is testing.
    @Test func logbookSearchesResolvedAndOtherListsSearchOpen() throws {
        let store = try makeStore()
        let open = store.createTodo(title: "Taxes", assignedDate: Date())
        let done = store.createTodo(title: "Taxes 2025", assignedDate: Date())
        done.setState(.completed)
        let all = [open, done]

        #expect(TodoSearch.matches(all, query: "taxes", in: .logbook).map(\.title) == ["Taxes 2025"])
        #expect(TodoSearch.matches(all, query: "taxes", in: .today).map(\.title) == ["Taxes"])
    }

    /// The same split, in the Inbox's own pool.
    @Test func inboxSearchesOpenWorkOnly() throws {
        let store = try makeStore()
        let open = store.createTodo(title: "Taxes")
        let done = store.createTodo(title: "Taxes 2025")
        done.setState(.completed)

        #expect(TodoSearch.matches([open, done], query: "taxes", in: .inbox).map(\.title) == ["Taxes"])
    }

    // MARK: Pool

    @Test func searchingInsideASpaceStaysInThatSpace() throws {
        let store = try makeStore()
        let work = store.createSpace(name: "Work")
        let home = store.createSpace(name: "Home")

        let workTask = store.createTodo(title: "Call plumber", space: work)
        let homeTask = store.createTodo(title: "Call dentist", space: home)
        let loose = store.createTodo(title: "Call mum")
        let all = [workTask, homeTask, loose]

        let results = TodoSearch.matches(all, query: "call", in: .space(work.uuid))

        #expect(results.map(\.title) == ["Call plumber"])
    }

    @Test func searchingInsideAProjectStaysInThatProject() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let other = store.createTodo(title: "Redesign", isProject: true)

        let inside = store.createTodo(title: "Write copy", parent: project)
        let outside = store.createTodo(title: "Write brief", parent: other)
        let all = [inside, outside]

        let results = TodoSearch.matches(all, query: "write", in: .project(project.uuid))

        #expect(results.map(\.title) == ["Write copy"])
    }

    /// A project's pool reaches all the way down, not just to direct children.
    @Test func projectSearchReachesNestedSubtasks() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let child = store.createTodo(title: "Write copy", parent: project)
        let grandchild = store.createTodo(title: "Write the headline", parent: child)

        let results = TodoSearch.matches(
            [child, grandchild],
            query: "headline",
            in: .project(project.uuid)
        )

        #expect(results.map(\.title) == ["Write the headline"])
    }

    /// The date lists drop their *window* when searching but keep their
    /// *membership* rule: an item the user cannot browse to because they have
    /// forgotten its date is still findable.
    @Test func dateListsSearchOutsideTheirWindow() throws {
        let store = try makeStore()
        let nextMonth = Calendar.current.date(byAdding: .day, value: 40, to: Date())
        let distant = store.createTodo(title: "Renew passport", assignedDate: nextMonth)

        #expect(TodoSearch.matches([distant], query: "passport", in: .today).count == 1)
        #expect(TodoSearch.matches([distant], query: "passport", in: .thisWeek).count == 1)
    }

    /// The reported bug: searching Today returned every to-do in the app,
    /// including undated Inbox capture that was never in Today.
    @Test func dateListsExcludeUndatedWork() throws {
        let store = try makeStore()
        let dated = store.createTodo(title: "Call plumber", assignedDate: Date())
        let undated = store.createTodo(title: "Call dentist")
        let all = [dated, undated]

        #expect(TodoSearch.matches(all, query: "call", in: .today).map(\.title) == ["Call plumber"])
        #expect(TodoSearch.matches(all, query: "call", in: .thisWeek).map(\.title) == ["Call plumber"])
    }

    /// A deadline with no assigned date is still dated work, so Today's search
    /// reaches it — Today's browsing list shows overdue items for the same
    /// reason.
    @Test func dateListsIncludeDueOnlyWork() throws {
        let store = try makeStore()
        let due = store.createTodo(title: "File taxes", dueDate: Date())

        #expect(TodoSearch.matches([due], query: "taxes", in: .today).count == 1)
    }

    /// The Inbox's field searches unfiled capture, not the whole app.
    @Test func inboxSearchStaysInTheInbox() throws {
        let store = try makeStore()
        let work = store.createSpace(name: "Work")
        let captured = store.createTodo(title: "Call plumber")
        let filed = store.createTodo(title: "Call dentist", space: work)
        let dated = store.createTodo(title: "Call mum", assignedDate: Date())
        let all = [captured, filed, dated]

        #expect(TodoSearch.matches(all, query: "call", in: .inbox).map(\.title) == ["Call plumber"])
    }

    /// Anytime is scheduled-but-undated work, matching how it browses.
    @Test func anytimeSearchesScheduledUndatedWork() throws {
        let store = try makeStore()
        let nextMonth = Calendar.current.date(byAdding: .day, value: 40, to: Date())
        let dated = store.createTodo(title: "Renew passport", assignedDate: nextMonth)
        let captured = store.createTodo(title: "Renew library card")
        let all = [dated, captured]

        // A dated item is in Anytime's bucket too, since a date is what
        // schedules it.
        #expect(TodoSearch.matches(all, query: "renew", in: .anytime).map(\.title) == ["Renew passport"])
    }

    /// Unlike the browsing lists, search is flat — a matching subtask is a
    /// result in its own right rather than something only reachable by first
    /// finding its parent.
    @Test func subtasksAreReturnedAsTopLevelResults() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Launch", isProject: true)
        let subtask = store.createTodo(title: "Book the venue", parent: project)

        let results = TodoSearch.matches([project, subtask], query: "venue")

        #expect(results.map(\.title) == ["Book the venue"])
    }

    // MARK: Focus

    /// A Focus hiding a space hides it from search too — otherwise the filter
    /// would leak the work it was set up to put away.
    @Test func focusHiddenSpacesAreExcluded() throws {
        let store = try makeStore()
        let work = store.createSpace(name: "Work")
        let task = store.createTodo(title: "Quarterly report", space: work)

        #expect(TodoSearch.matches([task], query: "report").count == 1)

        work.isHiddenByFocus = true
        #expect(TodoSearch.matches([task], query: "report").isEmpty)
    }
}
