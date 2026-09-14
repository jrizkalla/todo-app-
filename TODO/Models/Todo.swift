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

    /// The *week* this work is planned for, when it is planned by week rather
    /// than by day. Nil for everything else.
    ///
    /// Stored as the start of that week — midnight on its first day, by the
    /// user's week-start preference — rather than as a `thisWeek`/`nextWeek`
    /// enum, and that is the whole design. An enum would have to be rewritten
    /// on every row every Monday: what the user called "next week" becomes this
    /// week without anybody touching it, and a stored label would go on
    /// claiming otherwise until some migration pass caught up. An anchor date
    /// needs no such pass — "this week" is the anchor that equals the current
    /// week's start and "next week" is the one seven days on, so the lists
    /// re-sort themselves at midnight on the week boundary by asking the
    /// calendar rather than by being told.
    ///
    /// An anchor in a week that has already ended is the rollover's business;
    /// see `WeekScheduleRollover`.
    ///
    /// Mutually exclusive with `assignedDate` by construction — see
    /// `scheduleForWeek(_:)` and `clearWeekSchedule()`, which every write goes
    /// through. A to-do is scheduled for a day or for a week, never both.
    var weekAnchor: Date?

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

    // MARK: Recurrence
    //
    // A recurring to-do is not a separate entity. The *template* is a `Todo`
    // carrying these columns, and each generated occurrence is an ordinary
    // `Todo` pointing back at it through `recurrenceTemplate`. That is what
    // lets an instance be dragged, scheduled, completed, given subtasks, and
    // drawn on the calendar by every code path that already exists — a
    // separate `RecurringTodo` class would have had to re-implement all of it,
    // and would have doubled the archive and migration surface for no gain.
    //
    // `recurrenceModeRaw` being non-nil is what makes a to-do a template. Every
    // column here is optional so existing rows migrate without a value, and
    // primitive so CloudKit mirrors them.

    /// Backing storage for `RecurrenceRule.mode`. Non-nil marks a template.
    var recurrenceModeRaw: String?
    var recurrenceFrequencyRaw: String?
    var recurrenceInterval: Int?
    /// Selected weekdays for a weekly rule, as `Calendar` weekday numbers
    /// joined by commas ("2,5").
    ///
    /// A string rather than `[Int]`: CloudKit mirroring wants primitives, and a
    /// seven-element set does not earn a transformable column.
    var recurrenceWeekdaysRaw: String?
    var recurrenceDayOfMonth: Int?
    /// Time of day for instances, in minutes since midnight. Nil means the
    /// instances are whole-day items.
    var recurrenceTimeOfDayMinutes: Int?
    /// When the series stops, if it does.
    var recurrenceEndDate: Date?
    /// Backing storage for `RecurrenceRule.status`.
    var recurrenceStatusRaw: String?

    /// The date the *next* instance should be generated for.
    ///
    /// Held on the template rather than recomputed from the last instance every
    /// time, because the two disagree in the case that matters: an
    /// `.afterCompletion` rule measures from when the last instance was
    /// completed, and once that instance has been deleted there is nothing left
    /// to measure from. Storing the answer makes generation idempotent — the
    /// engine can run on every launch and every completion without producing
    /// duplicates.
    var recurrenceNextDate: Date?

    /// The template that generated this to-do, when it is an instance.
    ///
    /// Nullify rather than cascade: deleting a series should not delete the
    /// occurrences the user already has in hand, some of which may be done and
    /// part of their history. They simply stop being tied to a schedule.
    @Relationship(deleteRule: .nullify)
    var recurrenceTemplate: Todo?

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

    /// Occurrences generated from this to-do, when it is a template.
    ///
    /// The inverse of `recurrenceTemplate`; declaring it here is what gives
    /// SwiftData the one place to store the edge, and what lets a template ask
    /// for its own history without a fetch.
    @Relationship(deleteRule: .nullify, inverse: \Todo.recurrenceTemplate)
    var recurrenceInstances: [Todo]? = []

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
        weekSchedule: WeekSchedule? = nil,
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
        // Through the setter, so a caller passing both a date and a week gets
        // the same exclusion every other path enforces rather than a row that
        // is quietly in two places at once.
        if let weekSchedule {
            self.weekAnchor = WeekMath.anchor(for: weekSchedule)
            self.assignedDate = nil
            self.assignedHasTime = false
        }
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
    /// date, a week, or a home (project or space).
    var isScheduled: Bool {
        assignedDate != nil || dueDate != nil || weekAnchor != nil
            || space != nil || parent != nil
            || isRecurrenceTemplate
    }

    /// Plan this to-do into a week, clearing any day it was pinned to.
    ///
    /// The clearing is the point, and it is why every write goes through here
    /// rather than assigning `weekAnchor` directly. "Scheduled for Tuesday" and
    /// "scheduled for this week" are two answers to one question, so a to-do
    /// holding both is not more scheduled — it is a row that shows up in Today
    /// under a date the user replaced, and in This Week under a week they may
    /// have since moved on from. The later choice wins outright.
    ///
    /// `duration` survives, for the same reason it survives
    /// `clearScheduleForTemplate`: it says how long the work takes, which is
    /// true whichever day it lands on. So does `dueDate` — a deadline is a fact
    /// about the work rather than a placement, and picking a week to do
    /// something in says nothing about when it is owed.
    func scheduleForWeek(
        _ schedule: WeekSchedule,
        now: Date = Date(),
        calendar: Calendar? = nil
    ) {
        weekAnchor = WeekMath.anchor(for: schedule, now: now, calendar: calendar)
        assignedDate = nil
        assignedHasTime = false
    }

    /// Drop the week plan, leaving everything else alone.
    ///
    /// The counterpart called by every path that assigns a *day*, so that
    /// scheduling in either direction overrides the other rather than layering.
    func clearWeekSchedule() {
        weekAnchor = nil
    }

    /// Which week list this to-do belongs to right now, if either.
    ///
    /// Computed rather than stored — see `weekAnchor` for why. An anchor from a
    /// week that has ended reads as nil here, so a stale row drops out of both
    /// lists the moment the week turns, with or without the rollover having run.
    func weekSchedule(now: Date = Date(), calendar: Calendar? = nil) -> WeekSchedule? {
        guard let weekAnchor else { return nil }
        return WeekMath.schedule(forAnchor: weekAnchor, now: now, calendar: calendar)
    }

    /// A week plan the user set that the week has since moved past.
    ///
    /// What the rollover sweeps: still open, still anchored, and anchored to a
    /// week that has already ended.
    func hasExpiredWeekSchedule(now: Date = Date(), calendar: Calendar? = nil) -> Bool {
        guard let weekAnchor, !state.isResolved else { return false }
        return WeekMath.startOfWeek(containing: weekAnchor, calendar: calendar)
            < WeekMath.startOfWeek(containing: now, calendar: calendar)
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
        } else if assignedDate != nil || dueDate != nil || weekAnchor != nil {
            // A week plan files the same way a date does. It is a commitment to
            // do the work in a named stretch of time, which is the opposite of
            // the unsorted state the Inbox is for — and leaving it there would
            // have a to-do appear in both the Inbox and This Week at once.
            bucket = .anytime
        } else if isRecurrenceTemplate {
            // A template with no date is still not unorganized work — it is a
            // schedule. Anytime is where the spec asks a paused series to
            // appear, and filing it there rather than the Inbox keeps a
            // recurring to-do from reading as something the user forgot to
            // sort.
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

    /// Past its deadline, and still open.
    ///
    /// A deadline with a time is late the moment that time passes. One without
    /// is a *day*, so it is not late until that whole day has gone by — which
    /// means comparing against the start of today rather than against `now`.
    /// Comparing an untimed deadline to `now` would call a to-do due "today"
    /// overdue from one minute past midnight.
    ///
    /// This is deliberately the same rule `TodoQueries.overdueDescriptor`
    /// encodes as a predicate. The two are read against each other — a row this
    /// calls overdue must be one that fetch returns — so they have to agree,
    /// and an earlier same-day exemption here did not.
    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let dueDate, !state.isResolved else { return false }
        return dueDate < (dueHasTime ? now : calendar.startOfDay(for: now))
    }

    var isOverdue: Bool { isOverdue() }
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
        // The anchor rather than the `.thisWeek`/`.nextWeek` reading of it, so
        // the fingerprint is a fact about the row and not about when it was
        // taken. Keying on the reading would re-flag every week-planned to-do
        // as new every Monday, when nothing about it had moved.
        if let weekAnchor {
            let day = Calendar.current.startOfDay(for: weekAnchor)
            parts.append("week:\(Int(day.timeIntervalSince1970))")
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
    ///
    /// `subtaskState` is what the leftovers become, which is not always what
    /// the parent becomes: finishing a project usually means the work that
    /// never happened was *abandoned*, not done. Defaults to `newState` so the
    /// common "complete all" cascade reads unchanged.
    @discardableResult
    func setState(
        _ newState: CompletionState,
        cascadeToSubtasks: Bool = false,
        subtaskState: CompletionState? = nil
    ) -> Bool {
        if newState.isResolved && !blockingSubtasks.isEmpty {
            guard cascadeToSubtasks else { return false }
            let childState = subtaskState ?? newState
            for subtask in blockingSubtasks {
                subtask.setState(
                    childState,
                    cascadeToSubtasks: true,
                    subtaskState: childState
                )
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

    /// Every todo beneath this one, at any depth.
    ///
    /// Walks defensively with a visited set for the same reason `ancestors`
    /// does: a cycle already in the store must not hang the walk.
    var descendants: [Todo] {
        var result: [Todo] = []
        var seen: Set<UUID> = [uuid]
        var queue = orderedSubtasks

        while let node = queue.first {
            queue.removeFirst()
            guard seen.insert(node.uuid).inserted else { continue }
            result.append(node)
            queue.append(contentsOf: node.orderedSubtasks)
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


// MARK: - Recurrence

extension Todo {
    /// The recurrence rule this to-do carries as a template, if it is one.
    ///
    /// Projected from the primitive columns rather than stored as a composite,
    /// for the migration reason spelled out beside the columns themselves.
    /// Setting it to nil clears every column at once, which is what "stop
    /// recurring" means.
    var recurrenceRule: RecurrenceRule? {
        get {
            guard let modeRaw = recurrenceModeRaw,
                  let mode = RecurrenceMode(rawValue: modeRaw)
            else { return nil }

            return RecurrenceRule(
                mode: mode,
                frequency: recurrenceFrequencyRaw
                    .flatMap(RecurrenceFrequency.init(rawValue:)) ?? .weekly,
                interval: recurrenceInterval ?? 1,
                weekdays: Self.decodeWeekdays(recurrenceWeekdaysRaw),
                dayOfMonth: recurrenceDayOfMonth,
                timeOfDayMinutes: recurrenceTimeOfDayMinutes,
                endDate: recurrenceEndDate,
                status: recurrenceStatusRaw
                    .flatMap(RecurrenceStatus.init(rawValue:)) ?? .active
            )
        }
        set {
            guard let rule = newValue?.normalized() else {
                recurrenceModeRaw = nil
                recurrenceFrequencyRaw = nil
                recurrenceInterval = nil
                recurrenceWeekdaysRaw = nil
                recurrenceDayOfMonth = nil
                recurrenceTimeOfDayMinutes = nil
                recurrenceEndDate = nil
                recurrenceStatusRaw = nil
                recurrenceNextDate = nil
                return
            }

            recurrenceModeRaw = rule.mode.rawValue
            recurrenceFrequencyRaw = rule.frequency.rawValue
            recurrenceInterval = rule.interval
            recurrenceWeekdaysRaw = Self.encodeWeekdays(rule.weekdays)
            recurrenceDayOfMonth = rule.dayOfMonth
            recurrenceTimeOfDayMinutes = rule.timeOfDayMinutes
            recurrenceEndDate = rule.endDate
            recurrenceStatusRaw = rule.status.rawValue
        }
    }

    /// Strip the one-off scheduling a template must not carry.
    ///
    /// A template is a *schedule*, not an occurrence of one. Its dates belong
    /// to the instances it generates, and leaving them on the template itself
    /// makes it read as a task that is due — a row saying "Overdue" for a date
    /// that was only ever the series' starting point, which no amount of
    /// filtering downstream can undo because the row is telling the truth about
    /// the columns it has.
    ///
    /// `assignedDate` is not simply dropped: it is the date the user picked
    /// before making the to-do repeat, so it is the series' first occurrence
    /// and is moved into `recurrenceNextDate`, which is the field that actually
    /// means "when the next instance falls". Anything already scheduled there
    /// wins, since that is generation's own bookkeeping and is further along.
    ///
    /// The seed is normalized through the rule on the way in, because
    /// generation only runs `firstDate` when `recurrenceNextDate` is empty —
    /// filling it here skips that path, and an unnormalized seed would put the
    /// first occurrence at midnight on a rule that says three o'clock.
    ///
    /// `duration` stays. It describes how long the work takes, which is a
    /// property of the task and true of every occurrence — unlike a date, which
    /// can only ever be true of one.
    func clearScheduleForTemplate(calendar: Calendar = .current) {
        if recurrenceNextDate == nil, let assigned = assignedDate {
            recurrenceNextDate = recurrenceRule?
                .applyingTimeOfDay(to: assigned, calendar: calendar) ?? assigned
        }

        assignedDate = nil
        assignedHasTime = false
        // A week is a placement like a date, and a template has no placement of
        // its own — the same reasoning as `assignedDate` two lines up. Unlike
        // the date it is not preserved as a seed: "this week" names no
        // particular day for generation to start from.
        weekAnchor = nil
        // Deliberately cleared rather than carried onto each occurrence. One
        // fixed deadline copied onto a weekly series makes every instance after
        // the first one overdue from birth; a recurring deadline is a property
        // of the rule, which is what `recurrenceEndDate` and the time of day
        // are for.
        dueDate = nil
        dueHasTime = false
    }

    /// True when this to-do defines a series rather than being a single task.
    ///
    /// A template is never shown as an ordinary row: the list shows whichever
    /// instance is current instead. The one exception the spec calls for is a
    /// paused series, which surfaces in Anytime so it can be found and resumed.
    var isRecurrenceTemplate: Bool { recurrenceModeRaw != nil }

    /// True when this to-do was generated from a template.
    var isRecurrenceInstance: Bool { recurrenceTemplate != nil }

    /// True when the row should draw the recurring glyph — either because it is
    /// an occurrence of a series, or because it is the series itself.
    var isRecurring: Bool { isRecurrenceTemplate || isRecurrenceInstance }

    /// The rule governing this row, wherever it is defined.
    ///
    /// An instance carries no rule of its own; it reads its template's. Every
    /// surface that shows the schedule — the row chip, the details section, the
    /// picker — goes through this so an instance and its template can never
    /// disagree about what the schedule says.
    var effectiveRecurrenceRule: RecurrenceRule? {
        recurrenceRule ?? recurrenceTemplate?.recurrenceRule
    }

    /// The to-do that owns the schedule: the template itself, or an instance's.
    var recurrenceRoot: Todo? {
        isRecurrenceTemplate ? self : recurrenceTemplate
    }

    /// Instances of this template, newest first.
    var recurrenceInstanceList: [Todo] {
        (recurrenceInstances ?? []).sorted {
            ($0.assignedDate ?? $0.createdAt) > ($1.assignedDate ?? $1.createdAt)
        }
    }

    /// The occurrence currently standing in for the series, if any.
    ///
    /// The unresolved one — there is at most one live at a time by
    /// construction, since the engine will not generate a successor until the
    /// current one is resolved or its date has passed.
    var currentRecurrenceInstance: Todo? {
        recurrenceInstanceList.first { !$0.state.isResolved }
    }

    /// A paused or cancelled series shows itself in Anytime instead of an
    /// instance, flagged in the UI as a schedule rather than a task.
    var isDormantRecurrenceTemplate: Bool {
        guard let rule = recurrenceRule else { return false }
        return !rule.status.generatesInstances
    }

    /// True when this template is the row the lists should draw for its series.
    ///
    /// The rule the whole feature turns on: a series is represented by exactly
    /// one row. Normally that is the scheduled occurrence — the thing the user
    /// actually does — and the template stays out of the way. But a series with
    /// no live occurrence has nothing standing in for it, and hiding the
    /// template as well would make the whole series vanish from every list with
    /// no way to find it again.
    ///
    /// A paused or cancelled series is the usual reason there is no occurrence,
    /// but not the only one: an active series whose end date has passed, or one
    /// whose generation has not run yet, is in the same position. So the test is
    /// the absence of the instance rather than the status that usually causes
    /// it — see `TodoQueries.filterTemplates`.
    var standsInForItsSeries: Bool {
        isRecurrenceTemplate && currentRecurrenceInstance == nil
    }

    private static func encodeWeekdays(_ weekdays: Set<Int>) -> String? {
        guard !weekdays.isEmpty else { return nil }
        return weekdays.sorted().map(String.init).joined(separator: ",")
    }

    private static func decodeWeekdays(_ raw: String?) -> Set<Int> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int($0) })
    }
}
