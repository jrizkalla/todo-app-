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
    var colorHex: String = "#8E8E93"
    /// Sidebar ordering; the user can drag spaces to reorder.
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    /// Todos and projects filed in this space. Removing a space deletes the
    /// items inside it.
    @Relationship(deleteRule: .cascade, inverse: \Todo.space)
    var todos: [Todo]? = []

    init(
        name: String = "",
        symbolName: String = "square.stack",
        colorHex: String = "#8E8E93",
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

extension Space {
    var todoList: [Todo] { todos ?? [] }

    /// Projects in this space, in display order — what the sidebar lists
    /// beneath the space heading.
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
    var openCount: Int {
        todoList.filter { !$0.isProject && !$0.state.isResolved }.count
    }
}
