import Foundation
import SwiftData

/// The destinations reachable from the sidebar.
enum ListDestination: Hashable, Codable {
    case inbox
    case today
    case tomorrow
    case thisWeek
    case anytime
    case logbook
    case space(UUID)
    case project(UUID)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
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
        case .tomorrow: "sunrise"
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
    
    func filterCycles() -> Self {
        let uuidSet = Set(self.map { $0.uuid })
        return self.filter { todo in
            if let parent = todo.parent {
                !uuidSet.contains(parent.uuid)
            } else {
                true
            }
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
    ///
    /// Also drops anything the active Focus is hiding. Filtering here rather
    /// than in each destination means a Focus that hides a space keeps its work
    /// out of Today and This Week too, not just out of the sidebar — a filter
    /// that only hid the sidebar entry would still show the same to-dos in
    /// every date-based list.
    static func topLevel(_ todos: [Todo]) -> [Todo] {
        todos.filter { !$0.isHiddenByFocus }
    }
    
    /// Unresolved, unscheduled, unfiled items.
    static func inbox(_ todos: [Todo], includeResolved: Bool = false) -> [Todo] {
        topLevel(todos)
            .filter { $0.bucket == .inbox && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByOrder)
    }

    /// Everything due or scheduled on or before today, plus anything overdue.
    ///
    /// Overdue work stays in Today so it cannot be missed by moving past its
    /// date.
    static func today(_ todos: [Todo], calendar: Calendar = .current, now: Date = Date(), includeResolved: Bool = false) -> [Todo] {
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned < endOfToday { return true }
                if let due = todo.dueDate, due < endOfToday { return true }
                return false
            }
            .filter(includeResolved: includeResolved)
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Everything due or scheduled on the next day.
    ///
    /// Unlike `today`, this is a single day's window with no backward reach:
    /// overdue work belongs in Today, where it cannot be missed. Pulling it
    /// forward into Tomorrow as well would show the same late item in two lists
    /// and make Tomorrow read as busier than the day actually is.
    static func tomorrow(_ todos: [Todo], calendar: Calendar = .current, now: Date = Date(), includeResolved: Bool = false) -> [Todo] {
        let startOfTomorrow = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let endOfTomorrow = startOfTomorrow.addingTimeInterval(24 * 3600)

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned >= startOfTomorrow, assigned < endOfTomorrow { return true }
                if let due = todo.dueDate, due >= startOfTomorrow, due < endOfTomorrow { return true }
                return false
            }
            .filter(includeResolved: includeResolved)
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Today's work that has no time of day attached.
    ///
    /// The complement of what the schedule grid draws: anything with a time is
    /// already laid out against the hours, so the summary's "Any Time" card and
    /// the home screen widget list only what is left — work the user can slot
    /// in whenever. Built on `today` rather than on `assignedDate` alone so
    /// overdue and due-dated items are still included.
    static func untimedToday(
        _ todos: [Todo],
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false
    ) -> [Todo] {
        today(todos, calendar: calendar, now: now, includeResolved: includeResolved)
            .filter { !$0.assignedHasTime }
    }

    /// Items landing in the current week, by the user's week-start preference.
    static func thisWeek(_ todos: [Todo], calendar: Calendar = .current, now: Date = Date(), includeResolved: Bool = false) -> [Todo] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned < week.end { return true }
                if let due = todo.dueDate, due < week.end { return true }
                return false
            }
            .filter(includeResolved: includeResolved)
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Scheduled work with no specific home.
    static func anytime(_ todos: [Todo], includeResolved: Bool = false) -> [Todo] {
        topLevel(todos)
            .filter { $0.bucket == .anytime && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Completed and cancelled history, newest first.
    static func logbook(_ todos: [Todo]) -> [Todo] {
        // Deliberately not restricted to top-level items: work finished inside
        // a project is still finished work, and filtering by `parent == nil`
        // hid every completed subtask from the history. Projects themselves are
        // still excluded — the sidebar is where those live.
        todos
            .filter { $0.state.isResolved && !$0.isProject }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    /// Unresolved items past their due date.
    static func overdue(_ todos: [Todo], now: Date = Date()) -> [Todo] {
        topLevel(todos)
            .filter { $0.isOverdue }
            .filterCycles()
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// Contents of a space: its loose todos, excluding projects.
    static func inSpace(_ todos: [Todo], spaceID: UUID, includeResolved: Bool = false) -> [Todo] {
        todos
            .filter { $0.space?.uuid == spaceID && $0.parent == nil && !$0.isProject }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .sorted(by: sortByOrder)
    }

    /// Direct children of a project.
    static func inProject(_ todos: [Todo], projectID: UUID, includeResolved: Bool = false) -> [Todo] {
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

    /// The pool of to-dos a calendar lays out for a given destination.
    ///
    /// Narrower than the list query on purpose: the lists show one level of a
    /// container, while a calendar is about *when the work in this container
    /// happens* — so a space's calendar reaches into its projects and a
    /// project's calendar reaches down its whole subtask tree. Anything sitting
    /// on a day belongs on that day's grid regardless of how deeply it is filed.
    ///
    /// Projects themselves are left out: a project is a container, and a dated
    /// one would draw a block covering work that is already on the grid.
    static func calendarScope(_ todos: [Todo], for destination: ListDestination) -> [Todo] {
        switch destination {
        case .space(let id):
            return todos.filter { !$0.isProject && belongs(to: id, todo: $0) }
        case .project(let id):
            return todos.filter { !$0.isProject && isDescendant(of: id, todo: $0) }
        default:
            return todos
        }
    }

    /// The work a scoped calendar *cannot* draw: everything in the container
    /// with no date to place it on.
    ///
    /// The exact complement of what the grid lays out, over the same pool
    /// `calendarScope` defines — so the calendar and the side panel beside it
    /// add up to the whole container with nothing counted twice and nothing
    /// missing. Keyed on `assignedDate` alone, because that is the field the
    /// grid positions blocks by: an item with only a due date has still never
    /// been given a slot, and belongs in the panel where it can be dragged onto
    /// one.
    ///
    /// Resolved work is always excluded, matching `scheduled(_:on:)` — the pair
    /// is a picture of time still to be spent, and the Logbook is where
    /// finished work is read back.
    static func unscheduled(
        _ todos: [Todo],
        for destination: ListDestination,
        includeResolved: Bool = false
    ) -> [Todo] {
        calendarScope(topLevel(todos), for: destination)
            .filter { $0.assignedDate == nil }
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Whether a to-do is filed in a space, directly or through an ancestor.
    ///
    /// A subtask does not always carry its parent's space, so the walk upwards
    /// is what stops work inside a space's projects from going missing.
    private static func belongs(to spaceID: UUID, todo: Todo) -> Bool {
        if todo.space?.uuid == spaceID { return true }
        return todo.ancestors.contains { $0.space?.uuid == spaceID }
    }

    /// Whether a to-do sits anywhere beneath a project.
    private static func isDescendant(of projectID: UUID, todo: Todo) -> Bool {
        todo.ancestors.contains { $0.uuid == projectID }
    }

    /// Scheduled todos falling on a given day.
    ///
    /// Completed and cancelled work is always excluded, whatever the Show
    /// Resolved preference says. The grid is a picture of time still to be
    /// spent, and a finished item occupies a slot it no longer needs — it
    /// pushes live work into a cascade, blocks long-press creation on hours
    /// that are in fact free, and makes a full day out of one already done.
    /// The Logbook is where finished work is read back.
    ///
    /// Deliberately *not* `filterCycles()`, which the list queries use to stop
    /// a subtask drawing its own row beside the parent it is already nested
    /// under. A calendar has no nesting: a parent at 10am and its subtask at
    /// 1pm are two separate hours of the day, and dropping the child left a
    /// scheduled block simply missing from the grid.
    static func scheduled(_ todos: [Todo], on day: Date, calendar: Calendar = .current) -> [Todo] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        return topLevel(todos).filter { todo in
            guard let assigned = todo.assignedDate else { return false }
            return assigned >= start && assigned < end
        }
        .filter(includeResolved: false)
    }

    /// Day's todos without a time — shown in the calendar's all-day header.
    static func untimed(_ todos: [Todo], on day: Date, calendar: Calendar = .current) -> [Todo] {
        scheduled(todos, on: day, calendar: calendar)
            .filter { !$0.assignedHasTime }
            .sorted(by: sortByOrder)
    }

    /// Day's todos with a time — laid out as events.
    static func timed(_ todos: [Todo], on day: Date, calendar: Calendar = .current) -> [Todo] {
        scheduled(todos, on: day, calendar: calendar)
            .filter { $0.assignedHasTime }
            .sorted { ($0.assignedDate ?? .distantPast) < ($1.assignedDate ?? .distantPast) }
    }

    // MARK: Sorting

    private static func sortByOrder(_ a: Todo, _ b: Todo) -> Bool {
        if a.state.isResolved != b.state.isResolved { return !a.state.isResolved } // if a is not resolved, it is less than b
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        return a.createdAt < b.createdAt
    }

    /// Dated items first, in date order; undated items keep manual order.
    private static func sortByDateThenOrder(_ a: Todo, _ b: Todo) -> Bool {
        if a.state.isResolved != b.state.isResolved { return !a.state.isResolved } // if a is not resolved, it is less than b
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
