import Foundation
import SwiftUI
import SwiftData

/// Shared behavior for any title field that runs the natural-language parser.
///
/// Both the inline row editor and the detail view need the same three steps —
/// scan the title, show chips, apply the accepted one and strip its phrase — so
/// the logic lives here rather than being written twice.
@MainActor
@Observable
final class TitleSuggestionModel {
    private(set) var suggestions: [ParsedSuggestion] = []

    /// Recompute suggestions for `title`.
    ///
    /// - Parameters:
    ///   - todo: The todo being edited, excluded from project matches so a todo
    ///     cannot suggest moving into itself.
    ///   - context: Used to fetch the candidate containers. Only projects and
    ///     spaces are fetched — those are the two things a title can name and
    ///     the to-do can be filed into — so the old "everything in the store"
    ///     array is not scanned in full to keep a handful of rows.
    func refresh(for title: String, todo: Todo, context: ModelContext) {
        var parser = TitleParser()
        parser.projectNames = TodoQueries.projects(in: context)
            .filter { $0.uuid != todo.uuid && $0.uuid != todo.parent?.uuid }
            .map { (name: $0.title, uuid: $0.uuid) }

        // The space the to-do is already in is left out for the same reason its
        // current project is: a chip offering to file it where it already sits
        // does nothing when accepted.
        let spaces = (try? context.fetch(TodoQueries.allSpacesDescriptor())) ?? []
        parser.spaceNames = spaces
            .filter { $0.uuid != todo.space?.uuid }
            .map { (name: $0.name, uuid: $0.uuid) }

        suggestions = parser.suggestions(for: title)
    }

    func clear() {
        suggestions = []
    }

    /// Apply a suggestion and remove its matched phrase from the title.
    ///
    /// Returns the rewritten title so the caller can push it back into whatever
    /// binding drives its text field.
    @discardableResult
    func apply(
        _ suggestion: ParsedSuggestion,
        to todo: Todo,
        context: ModelContext,
        store: TodoStore
    ) -> String {
        switch suggestion.kind {
        case .schedule(let date, let hasTime):
            todo.assignedDate = date
            todo.assignedHasTime = hasTime
            // A date typed into the title is still a date, so it retires any
            // week the to-do was planned for — the same exclusion every other
            // scheduling path enforces.
            todo.clearWeekSchedule()
        case .scheduleWeek(let week):
            // And the exclusion in the other direction, which
            // `scheduleForWeek` applies for us.
            todo.scheduleForWeek(week)
        case .deadline(let date, let hasTime):
            todo.dueDate = date
            todo.dueHasTime = hasTime
        case .duration(let seconds):
            todo.duration = seconds
        case .project(_, let uuid):
            if let project = TodoQueries.todo(uuid: uuid, in: context) {
                store.move(todo, toParent: project)
            }
        case .space(_, let uuid):
            if let space = TodoQueries.space(uuid: uuid, in: context) {
                // Detached from any parent first: a to-do belongs to one
                // container, and a project it was under may live in a different
                // space entirely. Same rule the drop targets apply.
                store.move(todo, toParent: nil)
                store.move(todo, toSpace: space)
            }
        }

        let rewritten = TitleParser.removing(suggestion, from: todo.title)
        todo.title = rewritten
        store.update(todo) { _ in }

        refresh(for: rewritten, todo: todo, context: context)
        return rewritten
    }
}
