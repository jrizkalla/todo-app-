import Foundation
import SwiftData

/// The destinations reachable from the sidebar.
enum ListDestination: Hashable, Codable {
    case inbox
    case today
    case thisWeek
    case anytime
    case logbook
    case space(UUID)
    case project(UUID)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .thisWeek: "This Week"
        case .anytime: "Anytime"
        case .logbook: "Logbook"
        case .space: "Space"
        case .project: "Project"
        }
    }

    var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .today: "star"
        case .thisWeek: "calendar"
        case .anytime: "square.stack"
        case .logbook: "checkmark.circle"
        case .space: "folder"
        case .project: "list.bullet"
        }
    }
}

extension Array where Element == Todo {
    func filter(includeResolved : Bool = true) -> Self {
        self.filter { todo in
            !todo.state.isResolved || includeResolved
        }
    }
    
    func filterResolved(date: Date = Date()) -> Self {
        self.filter { todo in
            guard todo.state.isResolved, let resolvedAt = todo.resolvedAt else { return true }
            return Calendar.current.isDateInToday(resolvedAt)
        }
    }
}

/// Filtering rules behind each destination.
///
/// These operate on an already-fetched array rather than as `FetchDescriptor`
/// predicates: several rules (subtask exclusion, week bounds via `Calendar`)
/// are not expressible in `#Predicate`, and the working set here is small.
///
/// Main-actor-isolated because `@Model` types are: reading `Todo` off the main
/// actor is not safe. A widget or CLI reusing these filters does so from its own
/// main actor.
@MainActor
enum TodoQueries {

    /// Top-level items only — subtasks appear nested under their parent, not as
    /// separate rows.
    static func topLevel(_ todos: [Todo]) -> [Todo] {
        todos.filter { $0.parent == nil }
    }

    /// Unresolved, unscheduled, unfiled items.
    static func inbox(_ todos: [Todo], includeResolved: Bool) -> [Todo] {
        topLevel(todos)
            .filter { $0.bucket == .inbox && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .sorted(by: sortByOrder)
    }

    /// Everything due or scheduled on or before today, plus anything overdue.
    ///
    /// Overdue work stays in Today so it cannot be missed by moving past its
    /// date.
    static func today(_ todos: [Todo], calendar: Calendar = .current, now: Date = Date(), includeResolved: Bool) -> [Todo] {
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned < endOfToday { return true }
                if let due = todo.dueDate, due < endOfToday { return true }
                return false
            }
            .filter(includeResolved: includeResolved)
            .sorted(by: sortByDateThenOrder)
    }

    /// Items landing in the current week, by the user's week-start preference.
    static func thisWeek(_ todos: [Todo], calendar: Calendar = .current, now: Date = Date(), includeResolved: Bool) -> [Todo] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned < week.end { return true }
                if let due = todo.dueDate, due < week.end { return true }
                return false
            }
            .filter(includeResolved: includeResolved)
            .sorted(by: sortByDateThenOrder)
    }

    /// Scheduled work with no specific home.
    static func anytime(_ todos: [Todo], includeResolved: Bool) -> [Todo] {
        topLevel(todos)
            .filter { $0.bucket == .anytime && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .sorted(by: sortByDateThenOrder)
    }

    /// Completed and cancelled history, newest first.
    static func logbook(_ todos: [Todo]) -> [Todo] {
        // Deliberately not restricted to top-level items: work finished inside
        // a project is still finished work, and filtering by `parent == nil`
        // hid every completed subtask from the history. Projects themselves are
        // still excluded — the sidebar is where those live.
        todos
            .filter { !$0.isProject }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    /// Unresolved items past their due date.
    static func overdue(_ todos: [Todo], now: Date = Date()) -> [Todo] {
        topLevel(todos)
            .filter { $0.isOverdue }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// Contents of a space: its loose todos, excluding projects.
    static func inSpace(_ todos: [Todo], spaceID: UUID, includeResolved: Bool) -> [Todo] {
        todos
            .filter { $0.space?.uuid == spaceID && $0.parent == nil && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .sorted(by: sortByOrder)
    }

    /// Direct children of a project.
    static func inProject(_ todos: [Todo], projectID: UUID, includeResolved: Bool) -> [Todo] {
        todos
            .filter { $0.parent?.uuid == projectID }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .sorted(by: sortByOrder)
    }

    /// Projects not filed under any space — the sidebar's ungrouped section.
    static func looseProjects(_ todos: [Todo]) -> [Todo] {
        todos
            .filter { $0.isProject && $0.space == nil && !$0.state.isResolved }
            .sorted(by: sortByOrder)
    }

    // MARK: Calendar

    /// Scheduled todos falling on a given day.
    static func scheduled(_ todos: [Todo], on day: Date, calendar: Calendar = .current, includeResolved: Bool) -> [Todo] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        return topLevel(todos).filter { todo in
            guard let assigned = todo.assignedDate else { return false }
            return assigned >= start && assigned < end
        }
        .filter(includeResolved: includeResolved)
        .filterResolved()
    }

    /// Day's todos without a time — shown in the calendar's all-day header.
    static func untimed(_ todos: [Todo], on day: Date, calendar: Calendar = .current, includeResolved: Bool) -> [Todo] {
        scheduled(todos, on: day, calendar: calendar, includeResolved: includeResolved)
            .filter { !$0.assignedHasTime }
            .sorted(by: sortByOrder)
    }

    /// Day's todos with a time — laid out as events.
    static func timed(_ todos: [Todo], on day: Date, calendar: Calendar = .current, includeResolved: Bool) -> [Todo] {
        scheduled(todos, on: day, calendar: calendar, includeResolved: includeResolved)
            .filter { $0.assignedHasTime }
            .sorted { ($0.assignedDate ?? .distantPast) < ($1.assignedDate ?? .distantPast) }
    }

    // MARK: Sorting

    private static func sortByOrder(_ a: Todo, _ b: Todo) -> Bool {
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        return a.createdAt < b.createdAt
    }

    /// Dated items first, in date order; undated items keep manual order.
    private static func sortByDateThenOrder(_ a: Todo, _ b: Todo) -> Bool {
        let aDate = a.assignedDate ?? a.dueDate
        let bDate = b.assignedDate ?? b.dueDate

        switch (aDate, bDate) {
        case let (x?, y?):
            if x != y { return x < y }
            return sortByOrder(a, b)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return sortByOrder(a, b)
        }
    }
}
