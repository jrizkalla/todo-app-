import Foundation
import SwiftData

/// A single task, a project, or a subtask — all three are the same entity.
///
/// The spec says "a TODO can be upgraded to a project" and that projects "get
/// treated like TODOs", so promotion is a flag flip (`isProject`) rather than a
/// separate type. Subtasks are the same recursive relationship.
///
/// Every stored property is optional or has a default and there are no
/// `@Attribute(.unique)` constraints, which is what CloudKit mirroring requires.
@Model
final class Todo {
    /// Stable identity used by widgets, App Intents, and the CLI to address a
    /// todo without depending on SwiftData's `PersistentIdentifier` encoding.
    var uuid: UUID = UUID()

    /// Markdown source. Rendered inline (bold/italic/code) in list rows.
    var title: String = ""
    /// Markdown source supporting block constructs (headings, code fences).
    var notes: String = ""

    /// Backing storage for `state`. Raw values keep the column primitive.
    var stateRaw: String = CompletionState.open.rawValue
    /// Backing storage for `bucket`.
    var bucketRaw: String = Bucket.inbox.rawValue

    /// The day this work is planned for. `assignedHasTime` distinguishes
    /// "sometime Tuesday" from "Tuesday at 3pm", since `Date` always carries a
    /// time component.
    var assignedDate: Date?
    var assignedHasTime: Bool = false

    /// Planned length. Nil means the calendar falls back to the configurable
    /// default duration.
    var duration: TimeInterval?

    /// Deadline, distinct from `assignedDate` — the spec treats scheduling and
    /// due dates as separate properties.
    var dueDate: Date?
    var dueHasTime: Bool = false

    /// True when this todo is promoted to a project and appears in the sidebar.
    var isProject: Bool = false

    /// Set when the todo originated in the system Reminders app; drives the
    /// import badge in the Inbox.
    var importedFromReminders: Bool = false
    /// Identifier of the source `EKReminder`, kept so a re-scan can recognize
    /// an already-imported reminder instead of duplicating it.
    var sourceReminderID: String?

    /// Manual ordering within a list. Sidebar and list reordering write here.
    var sortIndex: Int = 0

    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    /// When the todo entered a resolved state, for "Logbook"-style history.
    var resolvedAt: Date?

    // MARK: Relationships

    /// The space this todo (or project) belongs to. Nil means it lives at the
    /// top level, in Inbox or Anytime.
    var space: Space?

    /// Parent todo when this is a subtask, or parent project when this todo
    /// belongs to one. Both are the same edge.
    var parent: Todo?

    /// Children of this todo. Deleting a parent removes its subtasks with it.
    @Relationship(deleteRule: .cascade, inverse: \Todo.parent)
    var subtasks: [Todo]? = []

    /// Attached reminders, removed along with the todo.
    @Relationship(deleteRule: .cascade, inverse: \Reminder.todo)
    var reminders: [Reminder]? = []

    init(
        title: String = "",
        notes: String = "",
        state: CompletionState = .open,
        bucket: Bucket = .inbox,
        assignedDate: Date? = nil,
        assignedHasTime: Bool = false,
        duration: TimeInterval? = nil,
        dueDate: Date? = nil,
        dueHasTime: Bool = false,
        isProject: Bool = false,
        space: Space? = nil,
        parent: Todo? = nil
    ) {
        self.uuid = UUID()
        self.title = title
        self.notes = notes
        self.stateRaw = state.rawValue
        self.bucketRaw = bucket.rawValue
        self.assignedDate = assignedDate
        self.assignedHasTime = assignedHasTime
        self.duration = duration
        self.dueDate = dueDate
        self.dueHasTime = dueHasTime
        self.isProject = isProject
        self.space = space
        self.parent = parent
        self.createdAt = Date()
        self.modifiedAt = Date()
        // A todo created with a date or a home is already scheduled.
        refileForCurrentScheduling()
    }
}

// MARK: - Typed accessors

extension Todo {
    var state: CompletionState {
        get { CompletionState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }

    var bucket: Bucket {
        get { Bucket(rawValue: bucketRaw) ?? .inbox }
        set { bucketRaw = newValue.rawValue }
    }

    /// SwiftData models optional-to-many relationships as `[Todo]?`; these
    /// accessors keep call sites free of `?? []`.
    var subtaskList: [Todo] { subtasks ?? [] }
    var reminderList: [Reminder] { reminders ?? [] }

    /// Subtasks in display order.
    var orderedSubtasks: [Todo] {
        subtaskList.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Direct children that are projects. Only meaningful on a `Space`-level
    /// query, but useful when a project holds child todos.
    var childTodos: [Todo] {
        orderedSubtasks.filter { !$0.isProject }
    }
}

// MARK: - Scheduling

extension Todo {
    /// The spec's definition: a todo is scheduled once it has a date, a due
    /// date, or a home (project or space).
    var isScheduled: Bool {
        assignedDate != nil || dueDate != nil || space != nil || parent != nil
    }

    /// Recompute which bucket this todo belongs in after a change to its dates
    /// or placement.
    ///
    /// Todos inside a space or project are addressed through that container, so
    /// they report `.space`. Otherwise a scheduled todo lands in Anytime and an
    /// unscheduled one falls back to the Inbox.
    func refileForCurrentScheduling() {
        if space != nil || parent != nil {
            bucket = .space
        } else if assignedDate != nil || dueDate != nil {
            bucket = .anytime
        } else {
            bucket = .inbox
        }
    }

    /// Effective calendar length, falling back to the user's configured default
    /// for timed todos that have no explicit duration.
    func effectiveDuration(defaultDuration: TimeInterval) -> TimeInterval {
        duration ?? defaultDuration
    }

    /// Start of the day this todo is scheduled for, if any.
    func scheduledDay(in calendar: Calendar = .current) -> Date? {
        assignedDate.map { calendar.startOfDay(for: $0) }
    }

    var isOverdue: Bool {
        guard let dueDate, !state.isResolved else { return false }
        return dueDate < Date()
    }
}

// MARK: - Completion rules

extension Todo {
    /// Subtasks that would block resolving this todo.
    ///
    /// The spec: a todo with subtasks cannot be completed or cancelled unless
    /// all of its subtasks are complete or cancelled.
    var blockingSubtasks: [Todo] {
        subtaskList.filter { !$0.state.isResolved }
    }

    /// Whether moving to `newState` is allowed without touching subtasks.
    func canTransition(to newState: CompletionState) -> Bool {
        guard newState.isResolved else { return true }
        return blockingSubtasks.isEmpty
    }

    /// Apply a state change.
    ///
    /// Returns `false` without mutating anything when the change is blocked by
    /// unresolved subtasks — the caller is expected to ask the user whether to
    /// cascade, then call `setState(_:cascadeToSubtasks: true)`.
    @discardableResult
    func setState(_ newState: CompletionState, cascadeToSubtasks: Bool = false) -> Bool {
        if newState.isResolved && !blockingSubtasks.isEmpty {
            guard cascadeToSubtasks else { return false }
            for subtask in blockingSubtasks {
                subtask.setState(newState, cascadeToSubtasks: true)
            }
        }

        state = newState
        resolvedAt = newState.isResolved ? Date() : nil
        touch()
        return true
    }

    /// The checkbox toggle: open/started become completed, resolved states go
    /// back to open. Other states are reachable by long-press.
    var toggledState: CompletionState {
        state.isResolved ? .open : .completed
    }

    func touch() {
        modifiedAt = Date()
    }
}

// MARK: - Placement

extension Todo {
    /// Move this todo into a space, enforcing the one-level nesting rule.
    ///
    /// Spaces contain projects; projects contain todos. A todo moved directly
    /// into a space loses any parent it had.
    func move(toSpace newSpace: Space?) {
        space = newSpace
        if newSpace != nil { parent = nil }
        refileForCurrentScheduling()
        touch()
    }

    /// Move this todo under a parent project (or detach it with nil).
    ///
    /// A child inherits its parent's space so it surfaces in the same section.
    func move(toParent newParent: Todo?) {
        parent = newParent
        if let newParent {
            space = newParent.space
        }
        refileForCurrentScheduling()
        touch()
    }

    /// Promote to a project so it appears in the sidebar, or demote back.
    ///
    /// A project cannot itself be nested under another project — the spec
    /// allows only one level (spaces containing projects), so promotion
    /// detaches it from any parent todo.
    func setIsProject(_ promoted: Bool) {
        isProject = promoted
        if promoted { parent = nil }
        refileForCurrentScheduling()
        touch()
    }

    /// Attach a new subtask, appended at the end of the current order.
    @discardableResult
    func addSubtask(_ subtask: Todo) -> Todo {
        subtask.sortIndex = (subtaskList.map(\.sortIndex).max() ?? -1) + 1
        subtask.move(toParent: self)
        return subtask
    }
}
