import Foundation
import SwiftData

/// A user-created area that groups projects and todos.
///
/// Spaces are the only container level above projects — the spec caps nesting
/// at one level, so a space never contains another space.
@Model
final class Space {
    var uuid: UUID = UUID()
    var name: String = ""
    /// SF Symbol shown beside the space in the sidebar.
    var symbolName: String = "square.stack"
    /// Accent color, stored as a hex string to stay a CloudKit primitive.
    var colorHex: String = Theme.Palette.defaultSpaceColor
    /// Sidebar ordering; the user can drag spaces to reorder.
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    /// Whether the active system Focus is currently hiding this space.
    ///
    /// Written by `SpaceFocusFilterIntent` when the user switches Focus, and
    /// read by the sidebar and list queries. Stored on the model rather than in
    /// `UserDefaults` because the filter arrives as a set of spaces and every
    /// view already observes the store — a Focus change then propagates through
    /// SwiftData's change notifications like any other edit.
    ///
    /// Defaults to `false` so a space is visible until a Focus says otherwise,
    /// which is what makes the feature opt-in: with no Focus filter configured
    /// nothing is ever hidden.
    var isHiddenByFocus: Bool = false

    /// Todos and projects filed in this space. Removing a space deletes the
    /// items inside it.
    @Relationship(deleteRule: .cascade, inverse: \Todo.space)
    var todos: [Todo]? = []

    init(
        name: String = "",
        symbolName: String = "square.stack",
        colorHex: String = Theme.Palette.defaultSpaceColor,
        sortIndex: Int = 0
    ) {
        self.uuid = UUID()
        self.name = name
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

/// Contents of a space, read through its relationship.
///
/// Each of these walks `todoList`, so they fault in every to-do filed in the
/// space to return a subset or a count. That is fine when the space is already
/// loaded and the caller wants its contents anyway — but a view drawing a row
/// per space pays it once per row.
///
/// `TodoQueries` has fetch-backed equivalents that answer the same questions in
/// SQLite: `projects(inSpace:in:)`, `openCount(inSpace:in:)`, and
/// `spaceContentCounts(spaceID:in:)`. Prefer those anywhere the number of
/// spaces is not known to be small — the sidebar uses them. Reach for these
/// when you hold one `Space` and want the objects themselves.
extension Space {
    var todoList: [Todo] { todos ?? [] }

    /// Projects in this space, in display order.
    ///
    /// See `TodoQueries.projects(inSpace:in:)` for the fetched form.
    var projects: [Todo] {
        todoList
            .filter { $0.isProject }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Loose todos filed directly in the space rather than in one of its
    /// projects.
    var looseTodos: [Todo] {
        todoList
            .filter { !$0.isProject && $0.parent == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Count of unresolved work, shown as the sidebar badge.
    ///
    /// See `TodoQueries.openCount(inSpace:in:)`, which counts without loading.
    var openCount: Int {
        todoList.filter { !$0.isProject && !$0.state.isResolved }.count
    }
}

// MARK: - Focus

extension Array where Element == Space {
    /// The spaces the active Focus allows, in display order.
    ///
    /// Every surface that lists spaces goes through this so a Focus change
    /// takes effect everywhere at once.
    var visibleUnderFocus: [Space] {
        filter { !$0.isHiddenByFocus }.sorted { $0.sortIndex < $1.sortIndex }
    }
}

extension Todo {
    /// Whether the active Focus hides this to-do, because the space holding it
    /// is filtered out.
    ///
    /// To-dos with no space are never hidden: Inbox and Anytime are not part of
    /// any space, so a Focus that selects spaces has nothing to say about them.
    var isHiddenByFocus: Bool {
        space?.isHiddenByFocus ?? false
    }
}
