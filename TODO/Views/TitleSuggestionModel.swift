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
    ///   - context: Used to fetch the candidate projects. Only projects are
    ///     fetched — the parser matches `#project` names and never looked at
    ///     anything else, so the old "everything in the store" array was
    ///     scanned in full to keep a handful of rows.
    func refresh(for title: String, todo: Todo, context: ModelContext) {
        var parser = TitleParser()
        parser.projectNames = TodoQueries.projects(in: context)
            .filter { $0.uuid != todo.uuid && $0.uuid != todo.parent?.uuid }
            .map { (name: $0.title, uuid: $0.uuid) }

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
        case .deadline(let date, let hasTime):
            todo.dueDate = date
            todo.dueHasTime = hasTime
        case .duration(let seconds):
            todo.duration = seconds
        case .project(_, let uuid):
            if let project = TodoQueries.todo(uuid: uuid, in: context) {
                store.move(todo, toParent: project)
            }
        }

        let rewritten = TitleParser.removing(suggestion, from: todo.title)
        todo.title = rewritten
        store.update(todo) { _ in }

        refresh(for: rewritten, todo: todo, context: context)
        return rewritten
    }
}
