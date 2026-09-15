import Foundation

/// Where the keyboard cursor sits in a flat list of items, and how the arrow
/// keys move it.
///
/// Deliberately free of SwiftUI and of `Todo`: it works on ids alone, so the
/// list and the calendar can share it, and so the movement rules can be tested
/// without building a view.
///
/// The rules here are the fiddly part of arrow-key navigation — what the first
/// Down does when nothing is selected, what happens when the selected row is
/// deleted or filtered away — and those are precisely what is easy to get
/// subtly wrong in a view body.
struct KeyboardCursor: Equatable {
    /// The currently selected item, if any.
    private(set) var selection: UUID?

    init(selection: UUID? = nil) {
        self.selection = selection
    }

    /// Direction of travel for an arrow key.
    enum Direction {
        case up, down
    }

    /// Move the cursor within `order`.
    ///
    /// With nothing selected, Down selects the first item and Up the last,
    /// which is what makes the arrow keys usable without a click first. At
    /// either end the cursor stays put rather than wrapping — wrapping in a
    /// to-do list means an accidental keypress jumps from today's first item to
    /// something weeks away.
    ///
    /// - Returns: `true` if the cursor moved, so the caller can decide whether
    ///   the keypress was consumed.
    @discardableResult
    mutating func move(_ direction: Direction, in order: [UUID]) -> Bool {
        guard !order.isEmpty else { return false }

        guard let current = selection, let index = order.firstIndex(of: current) else {
            selection = direction == .down ? order.first : order.last
            return true
        }

        let next = direction == .down ? index + 1 : index - 1
        guard order.indices.contains(next) else { return false }

        selection = order[next]
        return true
    }

    /// Select a specific item, or clear the selection with `nil`.
    mutating func select(_ id: UUID?) {
        selection = id
    }

    /// Drop a selection that names something no longer in `order`.
    ///
    /// Called when the visible set changes. Completing a to-do in Today filters
    /// it out from under the cursor, and a cursor left pointing at a row that
    /// is gone makes the next arrow key jump back to the top of the list.
    /// Landing on the nearest surviving neighbour keeps the user's place.
    mutating func reconcile(with order: [UUID], previousOrder: [UUID]) {
        guard let current = selection else { return }
        guard !order.contains(current) else { return }

        guard let oldIndex = previousOrder.firstIndex(of: current) else {
            selection = nil
            return
        }

        // The item that took its place, else the one before it.
        let successor = previousOrder[(oldIndex + 1)...].first { order.contains($0) }
        let predecessor = previousOrder[..<oldIndex].last { order.contains($0) }

        selection = successor ?? predecessor
    }
}

/// The keyboard actions a list or calendar can be asked to perform.
///
/// Modelled as a value rather than a pile of closures so the shortcut
/// definitions live in one place — `AppCommands` posts these, and whichever
/// surface has the keyboard interprets them.
enum KeyboardCommand: String, CaseIterable {
    /// Cmd+S — the quick scheduling panel.
    case schedule
    /// Cmd+K — toggle between open and done.
    case toggleDone
    /// Cmd+F — reveal search.
    case search
    /// Cmd+Return — open the detail view.
    case showDetail
    /// Cmd+N — create a to-do.
    case create
    /// Cmd+M — move to a space or project.
    case move
    /// Cmd+D — copy the selected to-do.
    case duplicate
    /// Cmd+Delete — delete the selected to-do.
    case delete
    /// Cmd+A — select every row in the list.
    case selectAll

    var notificationName: Notification.Name {
        Notification.Name("keyboardCommand.\(rawValue)")
    }

    /// Whether the command acts on the open screen rather than on a selected
    /// to-do.
    ///
    /// Everything else here needs something to act *on*, so it is delivered
    /// only to the surface holding the selection. These need only a screen to
    /// act *in*: Cmd+N means "new to-do in this list", Cmd+F means "search this
    /// list", and Cmd+A means "all the rows in this list" — none of them are
    /// about a row that is already picked, and all are pressed most often on a
    /// list just opened, where nothing is selected yet. Gating them on a
    /// selection sent them nowhere at exactly that moment.
    var actsOnView: Bool {
        switch self {
        case .create, .search, .selectAll: true
        case .schedule, .toggleDone, .showDetail, .move, .duplicate, .delete: false
        }
    }

    /// Menu title, so the shortcut is discoverable rather than folklore.
    var title: String {
        switch self {
        case .schedule: "Schedule…"
        case .toggleDone: "Toggle Completed"
        case .search: "Find"
        case .showDetail: "Show Details"
        case .create: "New To-Do"
        case .move: "Move to…"
        case .duplicate: "Duplicate"
        case .delete: "Delete"
        case .selectAll: "Select All"
        }
    }
}
