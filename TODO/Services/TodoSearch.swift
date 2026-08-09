import Foundation

/// Text search over to-dos.
///
/// Search is deliberately a *filter over a list*, not a separate index: the
/// working set is small enough to scan, and running it against the same arrays
/// the destinations already produce is what makes "search inside this list"
/// mean exactly the list the user is looking at.
///
/// Main-actor-isolated for the same reason `TodoQueries` is — reading `@Model`
/// properties off the main actor is not safe.
@MainActor
enum TodoSearch {

    /// Which side of the completion line a search is allowed to return.
    ///
    /// The Logbook is history, so searching it means searching finished work;
    /// every other list is live work, so searching it means the opposite. There
    /// is no "both" case on purpose — a single list showing a to-do and its
    /// cancelled twin reads as a duplicate, not as a wider net.
    enum Scope {
        /// Open and started work — the default everywhere but the Logbook.
        case unresolved
        /// Completed and cancelled work — the Logbook.
        case resolved

        func allows(_ todo: Todo) -> Bool {
            switch self {
            case .unresolved: !todo.state.isResolved
            case .resolved: todo.state.isResolved
            }
        }
    }

    /// Whether `query` has enough to it to search on.
    ///
    /// Whitespace alone is not a search: the field is revealed by a pull-down
    /// gesture, so a stray space should leave the list as it was rather than
    /// emptying it.
    static func isActive(_ query: String) -> Bool {
        !normalize(query).isEmpty
    }

    /// To-dos in `todos` matching `query`, restricted to `scope`.
    ///
    /// Results are flat and include subtasks. A search that only returned
    /// top-level rows would silently miss work filed inside a project, which is
    /// precisely the work that is hardest to find by browsing.
    static func matches(
        _ todos: [Todo],
        query: String,
        scope: Scope = .unresolved
    ) -> [Todo] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }

        return todos
            .filter { !$0.isHiddenByFocus }
            .filter(scope.allows)
            .filter { matches($0, terms: terms) }
            .sorted { rank($0, terms: terms) < rank($1, terms: terms) }
    }

    // MARK: Matching

    /// Every term has to appear somewhere in the to-do.
    ///
    /// Terms are AND-ed and matched independently of order, so "milk buy" finds
    /// "Buy milk" — with a small list, narrowing as the user types is more
    /// useful than ranking a long list of loose OR matches.
    private static func matches(_ todo: Todo, terms: [String]) -> Bool {
        let haystack = haystack(for: todo)
        return terms.allSatisfy { term in
            haystack.contains { $0.contains(term) }
        }
    }

    /// The text a to-do is searchable by.
    ///
    /// Notes are included because that is where the detail lives — a to-do
    /// titled "Call the bank" is often only findable by the account number
    /// written underneath it. The space and project names come along so
    /// searching "work" from the sidebar surfaces that space's contents.
    private static func haystack(for todo: Todo) -> [String] {
        var parts = [normalize(todo.title), normalize(todo.notes)]
        if let space = todo.space { parts.append(normalize(space.name)) }
        if let parent = todo.parent { parts.append(normalize(parent.title)) }
        return parts.filter { !$0.isEmpty }
    }

    /// Sort key: title matches first, then prefix matches, then the rest.
    ///
    /// A to-do whose *title* starts with what was typed is almost always the one
    /// being looked for; something that merely mentions the word in its notes is
    /// a fallback.
    private static func rank(_ todo: Todo, terms: [String]) -> Int {
        let title = normalize(todo.title)
        if terms.allSatisfy({ title.hasPrefix($0) }) { return 0 }
        if terms.allSatisfy({ title.contains($0) }) { return 1 }
        return 2
    }

    // MARK: Normalizing

    /// Case- and accent-insensitive form, so "resume" finds "résumé".
    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terms(in query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

// MARK: - Scoping a search to a destination

extension TodoSearch {
    /// The pool a search runs over when it is started from `destination`.
    ///
    /// Searching from inside a list stays inside that list, which is the point
    /// of having the field there at all — the sidebar's field is the one that
    /// searches everything.
    ///
    /// The pool is built from each list's *membership* rule, deliberately
    /// without its date window. Those are two different things: Today is "dated
    /// work" narrowed to "dated on or before today", and only the first half
    /// describes what belongs to the list. Dropping the window means searching
    /// Today still finds something scheduled for next month — the case the user
    /// cannot browse to because they have forgotten the date — while dropping
    /// undated Inbox clutter that was never in Today to begin with.
    static func pool(_ todos: [Todo], for destination: ListDestination) -> [Todo] {
        switch destination {
        case .space(let id):
            return todos.filter { $0.space?.uuid == id }
        case .project(let id):
            // Direct children, plus anything nested deeper inside them.
            return todos.filter { todo in
                todo.ancestors.contains { $0.uuid == id }
            }
        case .inbox:
            // Unfiled capture only. A subtask inside a project is filed, so the
            // Inbox's field should not reach it.
            return todos.filter { $0.bucket == .inbox && !$0.isProject }
        case .today, .thisWeek:
            // Dated work, at any date. Both lists are windows onto the same
            // pool, so both search it the same way.
            return todos.filter { $0.assignedDate != nil || $0.dueDate != nil }
        case .anytime:
            // Scheduled-but-undated, matching the browsing rule.
            return todos.filter { $0.bucket == .anytime && !$0.isProject }
        case .logbook:
            // History spans every list, so the pool is everything; the resolved
            // `scope` is what makes it history.
            return todos
        }
    }

    /// Which side of the completion line `destination` searches.
    static func scope(for destination: ListDestination) -> Scope {
        destination == .logbook ? .resolved : .unresolved
    }

    /// Search `todos` as the given destination's search field would.
    static func matches(
        _ todos: [Todo],
        query: String,
        in destination: ListDestination
    ) -> [Todo] {
        matches(
            pool(todos, for: destination),
            query: query,
            scope: scope(for: destination)
        )
    }
}
