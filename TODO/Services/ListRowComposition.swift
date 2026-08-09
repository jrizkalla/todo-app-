import Foundation

/// How a list turns a filtered set of to-dos into the rows actually drawn.
///
/// Two rules interact here, and getting them wrong is what put the same to-do
/// on screen twice:
///
/// 1. Most lists nest a to-do's subtasks under it, so a subtask is already on
///    screen without being a top-level row of its own.
/// 2. The focused row is pinned on screen even after it stops matching the
///    list, so accepting a suggestion mid-word does not yank it away.
///
/// Applied naively, rule 2 re-adds a subtask that rule 1 has already drawn.
/// Keeping both in one place — and out of the view — makes that interaction
/// testable rather than something only reproducible by hand.
///
/// Main-actor-isolated for the same reason `TodoQueries` is: reading `@Model`
/// properties off the main actor is not safe.
@MainActor
enum ListRowComposition {

    /// Whether `destination` draws subtasks nested under their parent.
    ///
    /// The Logbook lists finished work flat, and search results are flat too: a
    /// matching subtask is a result in its own right, so nesting it under a
    /// parent that also matched would show it twice.
    static func nestsSubtasks(destination: ListDestination, isSearching: Bool) -> Bool {
        destination != .logbook && !isSearching
    }

    /// The subtasks drawn beneath `todo`, empty where the list is already flat.
    static func nestedSubtasks(
        of todo: Todo,
        destination: ListDestination,
        isSearching: Bool
    ) -> [Todo] {
        nestsSubtasks(destination: destination, isSearching: isSearching)
            ? todo.orderedSubtasks
            : []
    }

    /// Whether `todo` is already on screen as a nested child of one of `rows`.
    ///
    /// Only the immediate parent is considered, matching `nestedSubtasks`,
    /// which nests exactly one level deep.
    static func isDrawnAsNestedSubtask(
        _ todo: Todo,
        in rows: [Todo],
        destination: ListDestination,
        isSearching: Bool
    ) -> Bool {
        guard nestsSubtasks(destination: destination, isSearching: isSearching) else { return false }
        guard let parentID = todo.parent?.uuid else { return false }
        return rows.contains { $0.uuid == parentID }
    }

    /// The top-level rows to draw, pinning the focused to-do on screen without
    /// duplicating one that is already drawn nested.
    static func rows(
        filtered: [Todo],
        focused: Todo?,
        destination: ListDestination,
        isSearching: Bool
    ) -> [Todo] {
        var result = filtered

        guard let focused else { return result }
        guard !result.contains(where: { $0.uuid == focused.uuid }) else { return result }
        guard !isDrawnAsNestedSubtask(
            focused,
            in: result,
            destination: destination,
            isSearching: isSearching
        ) else { return result }

        result.append(focused)
        return result
    }
}
