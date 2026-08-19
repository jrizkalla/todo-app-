import Foundation
import SwiftData
import FoundationModels

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
    var notesSummary: String = ""

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
    
    var endDate: Date? {
        guard let assignedDate, let duration else { return nil }
        return assignedDate.addingTimeInterval(duration)
    }

    /// Deadline, distinct from `assignedDate` — the spec treats scheduling and
    /// due dates as separate properties.
    var dueDate: Date?
    var dueHasTime: Bool = false

    /// True when this todo is promoted to a project and appears in the sidebar.
    var isProject: Bool = false

    /// Optional per-project color, as `#RRGGBB`.
    ///
    /// Only meaningful on a project. Nil means the project inherits its space's
    /// color, so setting a space color is enough for the common case.
    var colorHex: String?

    /// Set when the todo originated in the system Reminders app; drives the
    /// import badge in the Inbox.
    var importedFromReminders: Bool = false
    /// Identifier of the source `EKReminder`, kept so a re-scan can recognize
    /// an already-imported reminder instead of duplicating it.
    var sourceReminderID: String?

    /// Manual ordering within a list. Sidebar and list reordering write here.
    var sortIndex: Int = 0

    /// Whether this todo is unseen in the list it currently belongs to.
    ///
    /// Set when a todo arrives somewhere the user has not looked yet — imported
    /// from Reminders, newly given a date, or moved to another space or project
    /// — and cleared once they visit the list showing it. Drives the yellow dot.
    var isNew: Bool = false

    /// Fingerprint of the placement this todo was last viewed in.
    ///
    /// Comparing the current placement against this is what makes "moved to a
    /// new section" mean the same thing as "newly arrived": if the fingerprint
    /// differs, the todo is somewhere the user has not seen it.
    var lastViewedPlacement: String?

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
        // A to-do the user just created is not "new" to them; importers and
        // other automated sources call `markAsNew()` explicitly.
        markAsViewed()
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
        let now = Date()
        return if !dueHasTime && Calendar.current.isDate(now, inSameDayAs: dueDate) {
            false
        } else {
            dueDate < now
        }
    }
}

// MARK: - Color

extension Todo {
    /// The color this todo is displayed in, as `#RRGGBB`, or nil to use the
    /// app accent.
    ///
    /// Resolution runs nearest-first: the todo's own project color, then its
    /// parent project's, then its space's. Every surface — checkbox tint,
    /// calendar block, sidebar icon — reads this one property so a color change
    /// shows up everywhere at once.
    var resolvedColorHex: String? {
        if isProject, let colorHex { return colorHex }
        if let parentColor = parent?.colorHex { return parentColor }
        if let spaceColor = space?.colorHex { return spaceColor }
        return nil
    }
}

// MARK: - New / unviewed tracking

extension Todo {
    /// Identity of where this todo currently lives.
    ///
    /// Built from the bucket plus its container and scheduled day, so any move
    /// that puts the todo in front of the user somewhere new — a different
    /// space or project, or a newly assigned date — produces a different
    /// string. Scheduling uses day granularity so editing a time does not
    /// re-flag the item.
    var placementFingerprint: String {
        var parts: [String] = [bucketRaw]

        if let space { parts.append("space:\(space.uuid.uuidString)") }
        if let parent { parts.append("parent:\(parent.uuid.uuidString)") }

        if let assignedDate {
            let day = Calendar.current.startOfDay(for: assignedDate)
            parts.append("day:\(Int(day.timeIntervalSince1970))")
        }
        if let dueDate {
            let day = Calendar.current.startOfDay(for: dueDate)
            parts.append("due:\(Int(day.timeIntervalSince1970))")
        }

        return parts.joined(separator: "|")
    }

    /// Flag this todo as unseen in its current placement.
    func markAsNew() {
        isNew = true
        lastViewedPlacement = nil
    }

    /// Mark as seen where it now sits.
    func markAsViewed() {
        isNew = false
        lastViewedPlacement = placementFingerprint
    }

    /// Re-flag as new if the todo has moved since it was last viewed.
    ///
    /// Called after any edit that could change placement, which is how "moved
    /// to a new section" becomes new again without every caller remembering to
    /// set the flag.
    func refreshNewFlagAfterPlacementChange() {
        guard let lastViewedPlacement else {
            // Never viewed anywhere: stays new until the user sees it.
            isNew = true
            return
        }
        if lastViewedPlacement != placementFingerprint {
            isNew = true
            self.lastViewedPlacement = nil
        }
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
        refreshNewFlagAfterPlacementChange()
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
        refreshNewFlagAfterPlacementChange()
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

    /// This todo and every ancestor above it.
    ///
    /// Walks defensively with a visited set: a cycle already in the store —
    /// from a bad import or an older build — would otherwise hang the walk
    /// instead of being reported.
    var ancestors: [Todo] {
        var result: [Todo] = []
        var seen: Set<UUID> = [uuid]
        var current = parent

        while let node = current, seen.insert(node.uuid).inserted {
            result.append(node)
            current = node.parent
        }
        return result
    }

    /// Whether `candidate` may become a subtask of this todo.
    ///
    /// Rejects the todo itself, anything already parented here, and any
    /// ancestor — re-parenting an ancestor under its own descendant would make
    /// the tree circular, and every recursive walk over it non-terminating.
    func canAdopt(_ candidate: Todo) -> Bool {
        guard candidate.uuid != uuid else { return false }
        guard candidate.parent?.uuid != uuid else { return false }
        // A project is a top-level container, so it never becomes a subtask.
        guard !candidate.isProject else { return false }
        return !ancestors.contains { $0.uuid == candidate.uuid }
    }
}


extension Todo {
    func summarizeNotes() async {
        let title = title
        let notes = notes
        guard notes.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            self.notesSummary = ""
            return
        }
        notesSummary = "summarizing notes..."
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: """
                                    Summarize the notes of this task in a very short sentence suitable for display inside a small list view.
                                    The summary should be no more than a 10 word sentence.
                                    The title is visible in the row so don't include information in the summary about the title.
                                    Title: \(title)
                                    Notes: \(notes)
                                    """)
            let responseText = String(response.content.trimmingPrefix(/\s*-\s*/))
            print("Response: \(responseText)")
            Task { @MainActor in
                notesSummary = responseText
            }
        } catch {
            print(error)
            Task { @MainActor in
                notesSummary = notes.substring(to: notes.index(notes.startIndex, offsetBy: 100, limitedBy: notes.endIndex)!)
            }
        }
        
    }
}

