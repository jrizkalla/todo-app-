import Foundation
import SwiftData
import os

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

    /// Drop finished work older than the open-ended lists' history window.
    ///
    /// The in-memory twin of the `resolvedAt` bound in `resolvedVisible`; the
    /// two must agree, or the array path would discard rows the fetch admitted.
    func filterResolved(date: Date = Date(), calendar: Calendar = .current) -> Self {
        let startOfToday = calendar.startOfDay(for: date)
        let start = calendar.date(
            byAdding: .day, value: -TodoQueries.resolvedHistoryDays, to: startOfToday
        ) ?? startOfToday
        let end = startOfToday.addingTimeInterval(24 * 3600)

        return self.filter { todo in
            guard todo.state.isResolved, let resolvedAt = todo.resolvedAt else { return true }
            return resolvedAt >= start && resolvedAt < end
        }
    }

    /// Keep finished work inside a window, leaving open work untouched.
    ///
    /// The in-memory twin of `TodoQueries.resolvedWithin`; the two must agree.
    /// Used by the date lists that reach backwards without limit — Today and
    /// This Week — where the reach exists for overdue work and must not also
    /// admit the entire archive of completed items.
    ///
    /// A resolved item with no `resolvedAt` is dropped: it is finished but
    /// cannot be placed in time, and the alternative is showing it in every
    /// period forever.
    func filterResolved(within start: Date, _ end: Date) -> Self {
        self.filter { todo in
            guard todo.state.isResolved else { return true }
            guard let resolvedAt = todo.resolvedAt else { return false }
            return resolvedAt >= start && resolvedAt < end
        }
    }

    /// Drop recurrence templates, whose instances are what the lists show.
    ///
    /// The in-memory twin of `TodoQueries.notATemplate`; the two must agree, or
    /// the widget and the previews would show a schedule as though it were a
    /// task.
    func filterTemplates() -> Self {
        self.filter { !$0.isRecurrenceTemplate }
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

extension FetchDescriptor where T == Todo {
    mutating func prefetchRelated() {
        self.relationshipKeyPathsForPrefetching = [\.space]
    }
}

extension FetchDescriptor where T == Space {
    /// Fault in each space's to-dos alongside the spaces themselves.
    ///
    /// `Space.projects`, `looseTodos` and `openCount` all walk `todoList`, so a
    /// view that draws a row per space touches the relationship once per space
    /// — and without prefetching that is one round trip each, the N+1 the
    /// sidebar was paying on every redraw.
    ///
    /// Only for callers that actually read the contents. A view listing names
    /// alone should leave this off rather than pull every to-do in the store
    /// across to display none of them.
    mutating func prefetchTodos() {
        self.relationshipKeyPathsForPrefetching = [\.todos]
    }
}


/// Filtering rules behind each destination.
///
/// Each destination has two entry points:
///
/// * `descriptor(...)` / `…Descriptor(...)` — a `FetchDescriptor` carrying a
///   `#Predicate` and `SortDescriptor`s, so SQLite does the filtering and the
///   sorting and only matching rows are ever faulted into memory. This is what
///   the views use.
/// * the array-taking function — the same rules applied to an in-memory
///   collection. Kept because a handful of callers legitimately hold an array
///   (previews, the widget's snapshot, tests) and because the residual passes
///   below have to run somewhere.
///
/// Both paths are expressed through one set of rules per destination, so the
/// two cannot drift apart.
///
/// ## What a predicate cannot do
///
/// Three rules stay in memory, and every fetch that needs them applies them to
/// the fetched page rather than to the whole store:
///
/// * `filterCycles()` tests a row against *the rest of the result* — "drop a
///   subtask whose parent is also in this list" — which is not a property of a
///   row and so not a predicate.
/// * `calendarScope`'s space/project containment walks `ancestors` to arbitrary
///   depth; `#Predicate` has no transitive closure.
/// * `filterResolved()` compares `resolvedAt` against "today" through
///   `Calendar`. The *bounds* are hoisted out and compared in SQL (see
///   `resolvedVisible`), which is the part that matters for row count.
///
/// Everything else — state, bucket, projects, subtasks, date windows, and the
/// Focus filter — is now a predicate.
///
/// Main-actor-isolated because `@Model` types are: reading `Todo` off the main
/// actor is not safe. A widget or CLI reusing these filters does so from its own
/// main actor.
@MainActor
enum TodoQueries {

    // MARK: - Predicate building blocks
    //
    // Written as free-standing `#Predicate`s and combined by the descriptors
    // below. `#Predicate` cannot call a function or read a computed property —
    // it is a syntax macro over the expression, not a closure — so shared rules
    // have to be composed at the expression level rather than factored into
    // helpers the way the array code does it.

    /// The resolved states, spelled as raw values because `#Predicate` compares
    /// stored columns and `state` is a computed accessor over `stateRaw`.
    private static let resolvedRaws = [
        CompletionState.completed.rawValue,
        CompletionState.cancelled.rawValue,
    ]

    /// `topLevel`'s Focus rule: a to-do is hidden when the space holding it is.
    ///
    /// To-dos with no space are never hidden, matching `Todo.isHiddenByFocus` —
    /// the optional-chained `?? false` becomes an explicit nil check here.
    private static var notHiddenByFocus: Predicate<Todo> {
        #Predicate<Todo> { todo in
            todo.space == nil || todo.space?.isHiddenByFocus == false
        }
    }

    /// Recurrence templates are not to-dos the user does; they are schedules.
    ///
    /// The occurrence generated from a template is what appears in the dated
    /// lists, so admitting the template as well would show every recurring task
    /// twice — once as the thing to do today, and once as the rule that says to
    /// do it. `recurrenceModeRaw` is the stored marker; `#Predicate` cannot read
    /// the `isRecurrenceTemplate` computed property.
    ///
    /// Anytime deliberately does *not* use this: a paused or cancelled series
    /// has no instance standing in for it, and the spec asks for the template
    /// itself to surface there so it can be found and resumed.
    private static var notATemplate: Predicate<Todo> {
        #Predicate<Todo> { todo in todo.recurrenceModeRaw == nil }
    }

    /// The resolved half of the visibility rules, as one clause.
    ///
    /// Combines `filter(includeResolved:)` with `filterResolved()`: finished
    /// work is admitted only when the preference asks for it, and then only on
    /// the day it was finished. Both are folded into the fetch so an archive of
    /// completed work is never faulted in to be dropped.
    ///
    /// Factored out as a composed `Predicate` rather than written inline in
    /// each descriptor for two reasons: four destinations share it verbatim,
    /// and inlining it alongside the other clauses produced an expression the
    /// type-checker refused to check in reasonable time.
    private static func resolvedVisible(
        includeResolved: Bool,
        now: Date,
        calendar: Calendar
    ) -> Predicate<Todo> {
        let resolved = resolvedRaws
        let start = calendar.date(
            byAdding: .day, value: -resolvedHistoryDays, to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)

        return #Predicate<Todo> { todo in
            (includeResolved || !resolved.contains(todo.stateRaw))
                && (!resolved.contains(todo.stateRaw)
                    || todo.resolvedAt == nil
                    || (todo.resolvedAt.flatMap { $0 >= start && $0 < endOfToday } ?? false))
        }
    }

    /// How far back the open-ended lists show completed work.
    ///
    /// The Inbox, Anytime, spaces and projects have no date window of their
    /// own, so "show completed" in them would otherwise mean the entire
    /// archive. A month is enough to see what was just finished without the
    /// list turning into the Logbook.
    ///
    /// The date lists do not use this: their own window already bounds what
    /// they show — see `unresolvedUnless`.
    static let resolvedHistoryDays = 30

    /// Just the preference half, for the date lists.
    ///
    /// Tomorrow uses this on its own: its window is a single day with no
    /// backward reach, so the window already bounds what finished work can
    /// appear and nothing more is needed. Today and This Week reach backwards
    /// without limit and need `resolvedWithin` as well — see below.
    private static func unresolvedUnless(_ includeResolved: Bool) -> Predicate<Todo> {
        let resolved = resolvedRaws
        return #Predicate<Todo> { todo in
            includeResolved || !resolved.contains(todo.stateRaw)
        }
    }

    /// Keep finished work inside a window, while leaving open work alone.
    ///
    /// The lists that reach backwards without limit — Today and This Week —
    /// need this and the state rule both. Their window is deliberately
    /// open-ended so overdue work cannot fall out of the back, but that same
    /// reach applied to *resolved* rows meant "show completed" turned Today
    /// into the entire archive: every item ever completed was also dated before
    /// the end of today, so all of it qualified.
    ///
    /// Open work is untouched here, which is what preserves overdue: an
    /// unresolved item dated weeks ago still passes. Only resolved rows are
    /// held to the window, so what shows is the work *finished in that period*
    /// alongside everything still outstanding.
    private static func resolvedWithin(_ start: Date, _ end: Date) -> Predicate<Todo> {
        let resolved = resolvedRaws
        return #Predicate<Todo> { todo in
            !resolved.contains(todo.stateRaw)
                || (todo.resolvedAt.flatMap { $0 >= start && $0 < end } ?? false)
        }
    }

    /// A half-open day-or-range window on either date field.
    private static func datedBetween(_ start: Date, _ end: Date) -> Predicate<Todo> {
        #Predicate<Todo> { todo in
            (todo.assignedDate.flatMap { $0 >= start && $0 < end } ?? false)
                || (todo.dueDate.flatMap { $0 >= start && $0 < end } ?? false)
        }
    }

    /// Anything dated before `end` on either field, however far back.
    ///
    /// What Today and This Week both want: they are deadlines, not day windows,
    /// so overdue work stays in them rather than falling out the back.
    private static func datedBefore(_ end: Date) -> Predicate<Todo> {
        #Predicate<Todo> { todo in
            (todo.assignedDate.flatMap { $0 < end } ?? false)
                || (todo.dueDate.flatMap { $0 < end } ?? false)
        }
    }

    // MARK: - Descriptors

    /// Unresolved, unscheduled, unfiled items.
    ///
    /// `filterCycles` and `filterResolved` still run on the result — see the
    /// type comment — so this returns the descriptor and the caller pairs it
    /// with `finish(...)`.
    static func inboxDescriptor(
        includeResolved: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo> {
        let inboxRaw = Bucket.inbox.rawValue
        let focus = notHiddenByFocus
        let template = notATemplate
        let visible = resolvedVisible(
            includeResolved: includeResolved, now: now, calendar: calendar
        )

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo)
                    && todo.bucketRaw == inboxRaw
                    && !todo.isProject
                    && template.evaluate(todo)
                    && visible.evaluate(todo)
            },
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.space, \.parent]
        descriptor.prefetchRelated()
        return descriptor
    }

    /// Everything due or scheduled on or before today, plus anything overdue.
    ///
    /// Overdue work stays in Today so it cannot be missed by moving past its
    /// date.
    ///
    /// Open-ended backwards for *open* work, exactly as the array version is:
    /// anything unresolved and dated before the end of today — including work
    /// days or weeks overdue — is in the list. A half-open day window here
    /// would drop overdue items out of Today, which is the one list that must
    /// never lose them.
    ///
    /// Finished work is bounded to today, and that asymmetry is the point.
    /// Today is a list of what is outstanding plus what was struck off it
    /// *today*; something completed last week belongs to that day's Today and
    /// to the Logbook, not to this one. The two rules are separate predicates
    /// so the reach that overdue depends on is not the reach that decides how
    /// far back completed work is shown.
    static func todayDescriptor(
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> FetchDescriptor<Todo> {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = startOfToday.addingTimeInterval(24 * 3600)
        let focus = notHiddenByFocus
        // Open-ended backwards by default, which is what makes Today the list
        // overdue work cannot fall out of. A day-bounded window drops anything
        // dated before this morning — the exact items that most need to be
        // seen — so that shape is used only when the user has asked to hide
        // overdue work.
        let window = includeOverdue
            ? datedBefore(endOfToday)
            : datedBetween(startOfToday, endOfToday)
        let state = unresolvedUnless(includeResolved)
        // Completed items are held to today even though the window above
        // reaches past it. Without this, "show completed" listed every item
        // ever finished: each one is also dated before the end of today, so the
        // window alone admitted the whole archive.
        let finished = resolvedWithin(startOfToday, endOfToday)
        let template = notATemplate

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo) && window.evaluate(todo) && state.evaluate(todo)
                    && finished.evaluate(todo) && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = dateThenOrderSort
        return descriptor
    }

    /// Everything due or scheduled on the next day.
    ///
    /// Unlike `today`, this is a single day's window with no backward reach:
    /// overdue work belongs in Today, where it cannot be missed. Pulling it
    /// forward into Tomorrow as well would show the same late item in two lists
    /// and make Tomorrow read as busier than the day actually is.
    static func tomorrowDescriptor(
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false
    ) -> FetchDescriptor<Todo> {
        let startOfTomorrow = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let endOfTomorrow = startOfTomorrow.addingTimeInterval(24 * 3600)
        let focus = notHiddenByFocus
        let window = datedBetween(startOfTomorrow, endOfTomorrow)
        let state = unresolvedUnless(includeResolved)
        let template = notATemplate

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo) && window.evaluate(todo) && state.evaluate(todo)
                    && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = dateThenOrderSort
        return descriptor
    }

    /// Items landing in the current week, by the user's week-start preference.
    ///
    /// Open-ended backwards, exactly as the array version is: anything dated
    /// before the end of the week counts, however old.
    static func thisWeekDescriptor(
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> FetchDescriptor<Todo>? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let weekEnd = week.end
        let focus = notHiddenByFocus
        let state = unresolvedUnless(includeResolved)
        // Same rule as Today: open-ended backwards unless overdue work is
        // hidden, in which case the window starts where the week does.
        let window = includeOverdue
            ? datedBefore(weekEnd)
            : datedBetween(week.start, weekEnd)
        // And the same asymmetry: the backward reach is for overdue work, not
        // for the archive. Completed items are held to the week itself.
        let finished = resolvedWithin(week.start, weekEnd)
        let template = notATemplate

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo) && window.evaluate(todo) && state.evaluate(todo)
                    && finished.evaluate(todo) && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = dateThenOrderSort
        return descriptor
    }

    /// Scheduled work with no specific home.
    static func anytimeDescriptor(
        includeResolved: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo> {
        let anytimeRaw = Bucket.anytime.rawValue
        let focus = notHiddenByFocus
        let visible = resolvedVisible(
            includeResolved: includeResolved, now: now, calendar: calendar
        )
        // Anytime is the one list that shows a template — but only a *dormant*
        // one. An active series already has an occurrence standing in for it
        // somewhere, so admitting the template too would list the same
        // recurring task twice.
        let activeRaw = RecurrenceStatus.active.rawValue
        let dormantOrPlain = #Predicate<Todo> { todo in
            todo.recurrenceModeRaw == nil || todo.recurrenceStatusRaw != activeRaw
        }

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo)
                    && todo.bucketRaw == anytimeRaw
                    && !todo.isProject
                    && dormantOrPlain.evaluate(todo)
                    && visible.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = dateThenOrderSort
        return descriptor
    }

    /// Completed and cancelled history, newest first.
    ///
    /// Deliberately not restricted to top-level items: work finished inside a
    /// project is still finished work, and filtering by `parent == nil` hid
    /// every completed subtask from the history. Projects themselves are still
    /// excluded — the sidebar is where those live.
    ///
    /// Note this one has no Focus rule, matching the array version: the Logbook
    /// is history, and a Focus that hides a space should not rewrite the past.
    static func logbookDescriptor() -> FetchDescriptor<Todo> {
        let resolved = resolvedRaws

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                resolved.contains(todo.stateRaw) && !todo.isProject
            }
        )

        descriptor.sortBy = [SortDescriptor(\Todo.resolvedAt, order: .reverse)]
        return descriptor
    }

    /// Unresolved items past their due date.
    ///
    /// `isOverdue` is a computed property, so its two clauses — unresolved, and
    /// a due date in the past — are spelled out against the stored columns.
    static func overdueDescriptor(now: Date = Date()) -> FetchDescriptor<Todo> {
        let focus = notHiddenByFocus
        let unresolved = unresolvedUnless(false)
        
        let startOfToday = Calendar.current.startOfDay(for: now)

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo)
                    && unresolved.evaluate(todo)
                    && (todo.dueDate.flatMap { $0 < (
                        todo.dueHasTime ? now : startOfToday
                    ) } ?? false)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = [SortDescriptor(\Todo.dueDate)]
        return descriptor
    }

    /// Contents of a space: its loose todos, excluding projects.
    static func inSpaceDescriptor(
        spaceID: UUID,
        includeResolved: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo> {
        let visible = resolvedVisible(
            includeResolved: includeResolved, now: now, calendar: calendar
        )

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.space?.uuid == spaceID
                    && todo.parent == nil
                    && !todo.isProject
                    && visible.evaluate(todo)
            }
        )
        descriptor.sortBy = orderSort
        return descriptor
    }

    /// Direct children of a project.
    static func inProjectDescriptor(
        projectID: UUID,
        includeResolved: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo> {
        let visible = resolvedVisible(
            includeResolved: includeResolved, now: now, calendar: calendar
        )

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.parent?.uuid == projectID && visible.evaluate(todo)
            }
        )
        descriptor.sortBy = orderSort
        return descriptor
    }

    /// Projects not filed under any space — the sidebar's ungrouped section.
    static func looseProjectsDescriptor() -> FetchDescriptor<Todo> {
        let unresolved = unresolvedUnless(false)

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.isProject && todo.space == nil && unresolved.evaluate(todo)
            }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.subtasks]
        descriptor.sortBy = orderSort
        return descriptor
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
    /// Deliberately *not* cycle-filtered, which the list queries use to stop a
    /// subtask drawing its own row beside the parent it is already nested
    /// under. A calendar has no nesting: a parent at 10am and its subtask at
    /// 1pm are two separate hours of the day, and dropping the child left a
    /// scheduled block simply missing from the grid.
    static func scheduledDescriptor(
        on day: Date,
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo>? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let focus = notHiddenByFocus
        let unresolved = unresolvedUnless(false)
        let template = notATemplate

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo)
                    && (todo.assignedDate.flatMap { $0 >= start && $0 < end } ?? false)
                    && unresolved.evaluate(todo)
                    && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        return descriptor
    }

    /// Everything a calendar could ever draw: dated, unresolved, Focus-visible.
    ///
    /// Exposed as a standing predicate because `CalendarView` drives a `@Query`
    /// with it, and a query's filter has to be one expression written where the
    /// view is declared. Building it here keeps the rule beside the others and
    /// keeps that expression small enough for the type-checker.
    /// Dated, unresolved, Focus-visible work — carrying *either* date field.
    ///
    /// The pool the summary screen's cards are all windows on. Wider than
    /// `calendarDrawableDescriptor`, which needs an `assignedDate` because it
    /// positions blocks on a grid: `overdue` keys on `dueDate`, and `today`
    /// accepts either, so a row with only a deadline has to survive the fetch.
    ///
    /// `nonisolated` for the same reason as below.
    nonisolated static func datedUnresolvedDescriptor() -> FetchDescriptor<Todo> {
        let resolved = [
            CompletionState.completed.rawValue,
            CompletionState.cancelled.rawValue,
        ]
        let dated = #Predicate<Todo> { $0.assignedDate != nil || $0.dueDate != nil }
        let focus = #Predicate<Todo> {
            $0.space == nil || $0.space?.isHiddenByFocus == false
        }
        let unresolved = #Predicate<Todo> { !resolved.contains($0.stateRaw) }
        // A template is a schedule, not a block of time — its instances are
        // what the grid draws.
        let template = #Predicate<Todo> { $0.recurrenceModeRaw == nil }

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                dated.evaluate(todo) && focus.evaluate(todo) && unresolved.evaluate(todo)
                    && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = [SortDescriptor(\Todo.assignedDate), SortDescriptor(\Todo.dueDate)]
        return descriptor
    }

    /// `nonisolated` so it can be used as a `@Query`'s default descriptor, which
    /// is evaluated as a property initializer outside any actor.
    nonisolated static func calendarDrawableDescriptor() -> FetchDescriptor<Todo> {
        let resolved = [
            CompletionState.completed.rawValue,
            CompletionState.cancelled.rawValue,
        ]
        let dated = #Predicate<Todo> { $0.assignedDate != nil }
        let focus = #Predicate<Todo> {
            $0.space == nil || $0.space?.isHiddenByFocus == false
        }
        let unresolved = #Predicate<Todo> { !resolved.contains($0.stateRaw) }
        let template = #Predicate<Todo> { $0.recurrenceModeRaw == nil }

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                dated.evaluate(todo) && focus.evaluate(todo) && unresolved.evaluate(todo)
                    && template.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = [SortDescriptor(\Todo.assignedDate)]
        return descriptor
    }

    /// Scheduled todos anywhere in a range of days.
    ///
    /// What a calendar actually draws: one fetch covering the whole visible
    /// span, which the per-day accessors then slice in memory. A day-at-a-time
    /// predicate would mean seven fetches for a week — and the array version
    /// meant seven passes over every to-do in the store.
    ///
    /// `end` is exclusive, so callers pass the start of the day *after* the
    /// last visible one.
    static func scheduledDescriptor(
        from start: Date,
        to end: Date
    ) -> FetchDescriptor<Todo> {
        let focus = notHiddenByFocus
        let unresolved = unresolvedUnless(false)

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo)
                    && (todo.assignedDate.flatMap { $0 >= start && $0 < end } ?? false)
                    && unresolved.evaluate(todo)
            }
        )
        descriptor.prefetchRelated()
        descriptor.sortBy = [SortDescriptor(\Todo.assignedDate)]
        return descriptor
    }

    /// The `untimed` slice of an already-fetched range. See `timedOn`.
    static func untimedOn(
        _ fetched: [Todo],
        day: Date,
        for destination: ListDestination = .today,
        calendar: Calendar = .current
    ) -> [Todo] {
        onDay(fetched, day: day, for: destination, calendar: calendar)
            .filter { !$0.assignedHasTime }
            .sorted(by: sortByOrder)
    }

    /// The `timed` slice of an already-fetched range.
    ///
    /// The day window and the container walk are applied here rather than
    /// re-fetching: the rows are already in memory, and slicing one day out of
    /// a week is a comparison, not a query.
    static func timedOn(
        _ fetched: [Todo],
        day: Date,
        for destination: ListDestination = .today,
        calendar: Calendar = .current
    ) -> [Todo] {
        onDay(fetched, day: day, for: destination, calendar: calendar)
            .filter { $0.assignedHasTime }
            .sorted { ($0.assignedDate ?? .distantPast) < ($1.assignedDate ?? .distantPast) }
    }

    /// Rows from a fetched range that fall on one day, within a container.
    private static func onDay(
        _ fetched: [Todo],
        day: Date,
        for destination: ListDestination,
        calendar: Calendar
    ) -> [Todo] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let onDay = fetched.filter { todo in
            guard let assigned = todo.assignedDate else { return false }
            return assigned >= start && assigned < end
        }
        return calendarScope(onDay, for: destination)
    }

    /// Day's todos without a time — shown in the calendar's all-day header.
    static func untimedDescriptor(
        on day: Date,
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo>? {
        guard var descriptor = scheduledDescriptor(on: day, calendar: calendar),
              let scheduled = descriptor.predicate else { return nil }

        descriptor.predicate = #Predicate<Todo> { todo in
            scheduled.evaluate(todo) && !todo.assignedHasTime
        }
        descriptor.sortBy = orderSort
        return descriptor
    }

    /// Day's todos with a time — laid out as events.
    static func timedDescriptor(
        on day: Date,
        calendar: Calendar = .current
    ) -> FetchDescriptor<Todo>? {
        guard var descriptor = scheduledDescriptor(on: day, calendar: calendar),
              let scheduled = descriptor.predicate else { return nil }

        descriptor.predicate = #Predicate<Todo> { todo in
            scheduled.evaluate(todo) && todo.assignedHasTime
        }
        descriptor.sortBy = [SortDescriptor(\Todo.assignedDate)]
        return descriptor
    }

    /// The undated remainder of a container — the side panel beside a calendar.
    ///
    /// Only the date and state rules are predicates; the containment rule is
    /// the `ancestors` walk, which `unscheduled(_:for:)` applies to the result.
    static func unscheduledDescriptor(includeResolved: Bool = false) -> FetchDescriptor<Todo> {
        let focus = notHiddenByFocus
        let state = unresolvedUnless(includeResolved)
        let template = notATemplate

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                focus.evaluate(todo) && todo.assignedDate == nil && state.evaluate(todo)
                    && template.evaluate(todo)
            }
        )
        descriptor.sortBy = dateThenOrderSort
        return descriptor
    }

    // MARK: - Fetching

    /// Runs a descriptor, returning an empty list rather than throwing.
    ///
    /// A failed fetch is a bug in the predicate, not a condition a list view can
    /// do anything about, so it is logged and the list draws empty.
    static func fetch(_ descriptor: FetchDescriptor<Todo>, in context: ModelContext) -> [Todo] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLog.data.error("Todo fetch failed: \(String(describing: error))")
            return []
        }
    }

    /// Every project in the store, for pickers and the title parser's `#project`
    /// matching.
    ///
    /// Projects are a fraction of a to-do list, so fetching them by predicate
    /// replaces scanning every row to keep the handful that are containers.
    static func projectsDescriptor() -> FetchDescriptor<Todo> {
        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.isProject }
        )
        descriptor.sortBy = orderSort
        return descriptor
    }

    static func projects(in context: ModelContext) -> [Todo] {
        fetch(projectsDescriptor(), in: context)
    }

    /// One to-do by its stable `uuid`.
    ///
    /// A point fetch with `fetchLimit = 1`, replacing the `todos.first { ... }`
    /// scans the views used to run over an all-rows `@Query`.
    static func todo(uuid: UUID, in context: ModelContext) -> Todo? {
        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.uuid == uuid }
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor, in: context).first
    }

    // MARK: - Spaces

    /// Spaces the active Focus allows, in display order.
    ///
    /// The `visibleUnderFocus` rule as a fetch: `isHiddenByFocus` is a stored
    /// column and `sortIndex` is a sort, so both belong in SQLite rather than
    /// in a filter-then-sort over every space the store holds.
    ///
    /// `prefetchTodos` because the sidebar — this descriptor's reason for
    /// existing — reads `openCount` and `projects` for every row it draws.
    ///
    /// `nonisolated` so it can configure a `@Query`, which is initialized
    /// outside any actor.
    nonisolated static func visibleSpacesDescriptor() -> FetchDescriptor<Space> {
        var descriptor = FetchDescriptor<Space>(
            predicate: #Predicate<Space> { !$0.isHiddenByFocus }
        )
        descriptor.sortBy = [SortDescriptor(\Space.sortIndex)]
        descriptor.prefetchTodos()
        return descriptor
    }

    /// Every space in display order, Focus-hidden ones included.
    ///
    /// For the pickers, where a Focus filter has no business narrowing what a
    /// to-do can be filed into: hiding a space from the sidebar is about what
    /// the user is looking at now, not about where work is allowed to go.
    ///
    /// No prefetch — the pickers show names, not contents.
    nonisolated static func allSpacesDescriptor() -> FetchDescriptor<Space> {
        var descriptor = FetchDescriptor<Space>()
        descriptor.sortBy = [SortDescriptor(\Space.sortIndex)]
        return descriptor
    }

    /// How many spaces the active Focus is hiding, counted in SQLite.
    ///
    /// The sidebar footer notes this so a missing space never looks like data
    /// loss; it only ever needed the number.
    static func hiddenSpaceCount(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Space>(
            predicate: #Predicate<Space> { $0.isHiddenByFocus }
        )
        do {
            return try context.fetchCount(descriptor)
        } catch {
            AppLog.data.error("Hidden space count failed: \(String(describing: error))")
            return 0
        }
    }

    /// Projects filed in a space, in display order.
    ///
    /// Fetched by predicate rather than read off `space.projects`, which walks
    /// the whole relationship — every loose to-do in the space included — to
    /// keep the handful that are containers.
    ///
    /// Resolved projects are left out, matching `looseProjectsDescriptor`: the
    /// sidebar is a list of places to put work, and a finished project is not
    /// one. It stays reachable through the Logbook.
    ///
    /// - Parameter includeResolved: Pass true for callers that need every
    ///   project regardless of state, such as counting a space's contents.
    static func projectsDescriptor(
        inSpace spaceID: UUID,
        includeResolved: Bool = false
    ) -> FetchDescriptor<Todo> {
        let unresolved = unresolvedUnless(includeResolved)

        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.space?.uuid == spaceID && todo.isProject && unresolved.evaluate(todo)
            }
        )
        descriptor.sortBy = [SortDescriptor(\Todo.sortIndex)]
        return descriptor
    }

    static func projects(
        inSpace spaceID: UUID,
        in context: ModelContext,
        includeResolved: Bool = false
    ) -> [Todo] {
        fetch(projectsDescriptor(inSpace: spaceID, includeResolved: includeResolved), in: context)
    }

    /// The sidebar badge: unresolved, non-project work filed in a space.
    ///
    /// `Space.openCount` faults in every to-do in the space to count a subset;
    /// this asks SQLite for the number.
    static func openCount(inSpace spaceID: UUID, in context: ModelContext) -> Int {
        let resolved = resolvedRaws
        let descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.space?.uuid == spaceID
                    && !todo.isProject
                    && !resolved.contains(todo.stateRaw)
            }
        )
        do {
            return try context.fetchCount(descriptor)
        } catch {
            AppLog.data.error("Space open count failed: \(String(describing: error))")
            return 0
        }
    }

    /// What deleting a space would take with it, split the way the prompt reads.
    ///
    /// Two counts rather than a fetch of the contents: the dialog quotes
    /// numbers, and a space holding a year of work should not have to load it
    /// to say so.
    static func spaceContentCounts(
        spaceID: UUID,
        in context: ModelContext
    ) -> (projects: Int, others: Int) {
        let projectsDescriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.space?.uuid == spaceID && $0.isProject }
        )
        let othersDescriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.space?.uuid == spaceID && !$0.isProject }
        )
        do {
            return (
                try context.fetchCount(projectsDescriptor),
                try context.fetchCount(othersDescriptor)
            )
        } catch {
            AppLog.data.error("Space content count failed: \(String(describing: error))")
            return (0, 0)
        }
    }

    /// One space by its stable `uuid`.
    static func space(uuid: UUID, in context: ModelContext) -> Space? {
        var descriptor = FetchDescriptor<Space>(
            predicate: #Predicate<Space> { $0.uuid == uuid }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.todos]
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            AppLog.data.error("Space fetch failed: \(String(describing: error))")
            return nil
        }
    }

    /// A destination's descriptor, for driving a `@Query`.
    ///
    /// `thisWeek` can fail to resolve its week interval; rather than make every
    /// caller handle an optional, that case falls back to a descriptor matching
    /// nothing, which is what the array version's `return []` did.
    static func descriptor(
        for destination: ListDestination,
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> FetchDescriptor<Todo> {
        switch destination {
        case .inbox:
            return inboxDescriptor(includeResolved: includeResolved, now: now, calendar: calendar)
        case .today:
            return todayDescriptor(
                calendar: calendar,
                now: now,
                includeResolved: includeResolved,
                includeOverdue: includeOverdue
            )
        case .tomorrow:
            // Tomorrow has no backward reach to begin with — overdue work
            // belongs in Today — so the preference does not apply here.
            return tomorrowDescriptor(calendar: calendar, now: now, includeResolved: includeResolved)
        case .thisWeek:
            return thisWeekDescriptor(
                calendar: calendar,
                now: now,
                includeResolved: includeResolved,
                includeOverdue: includeOverdue
            ) ?? matchNothingDescriptor
        case .anytime:
            return anytimeDescriptor(includeResolved: includeResolved, now: now, calendar: calendar)
        case .logbook:
            return logbookDescriptor()
        case .space(let id):
            return inSpaceDescriptor(
                spaceID: id, includeResolved: includeResolved, now: now, calendar: calendar
            )
        case .project(let id):
            return inProjectDescriptor(
                projectID: id, includeResolved: includeResolved, now: now, calendar: calendar
            )
        }
    }

    private static var matchNothingDescriptor: FetchDescriptor<Todo> {
        FetchDescriptor<Todo>(predicate: #Predicate<Todo> { _ in false })
    }

    /// The residual passes for the side panel's undated remainder.
    ///
    /// The counterpart of `finish(_:for:)` for `unscheduledDescriptor`: the
    /// fetch has already applied the date and state rules, so what is left is
    /// the container walk and the ordering.
    static func unscheduledRemainder(
        _ fetched: [Todo],
        for destination: ListDestination
    ) -> [Todo] {
        calendarScope(fetched, for: destination)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// The in-memory passes a fetched page still needs, per destination.
    ///
    /// Split out from the fetch so a `@Query`-driven view can apply exactly the
    /// same residual rules to rows SwiftData delivered, and get a result
    /// identical to `todos(for:in:)`.
    static func finish(_ fetched: [Todo], for destination: ListDestination) -> [Todo] {
        switch destination {
        case .inbox:
            return fetched.filterCycles()
        case .today, .tomorrow, .thisWeek, .anytime:
            return fetched.filterCycles().sorted(by: sortByDateThenOrder)
        case .logbook:
            // SQL orders NULLs first under `.reverse`; the array version ranks a
            // nil `resolvedAt` as `.distantPast`, i.e. last.
            return fetched.sorted {
                ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast)
            }
        case .space, .project:
            return fetched
        }
    }

    /// A destination's rows, filtered and sorted in SQLite.
    ///
    /// The one entry point the list pane needs: it maps a destination to its
    /// descriptor, fetches, and applies the residual in-memory passes that no
    /// predicate can express.
    static func todos(
        for destination: ListDestination,
        in context: ModelContext,
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> [Todo] {
        let fetched = fetch(
            descriptor(
                for: destination,
                calendar: calendar,
                now: now,
                includeResolved: includeResolved,
                includeOverdue: includeOverdue
            ),
            in: context
        )
        return finish(fetched, for: destination)
    }

    /// How many rows a destination holds, without faulting the rows in.
    ///
    /// The sidebar badges only ever showed a count, so they used to fetch the
    /// whole store and measure the array. `fetchCount` answers from SQLite.
    ///
    /// Counts skip `filterCycles`, so a badge can read one higher than the list
    /// when a subtask and its parent are both in the same date window. Doing it
    /// exactly would mean faulting in every row, which is what the badge is
    /// avoiding.
    static func count(
        for destination: ListDestination,
        in context: ModelContext,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Int {
        let descriptor: FetchDescriptor<Todo>?
        switch destination {
        case .inbox:
            descriptor = inboxDescriptor(now: now, calendar: calendar)
        case .today:
            descriptor = todayDescriptor(calendar: calendar, now: now)
        case .tomorrow:
            descriptor = tomorrowDescriptor(calendar: calendar, now: now)
        case .thisWeek:
            descriptor = thisWeekDescriptor(calendar: calendar, now: now)
        case .anytime:
            descriptor = anytimeDescriptor(now: now, calendar: calendar)
        default:
            return 0
        }

        guard let descriptor else { return 0 }
        do {
            return try context.fetchCount(descriptor)
        } catch {
            AppLog.data.error("Todo count failed: \(String(describing: error))")
            return 0
        }
    }

    /// Scheduled work on a day, fetched and then narrowed to a container.
    ///
    /// `destination` is applied in memory because containment is an `ancestors`
    /// walk — but the day window and the state rule have already cut the fetch
    /// down to one day's rows, which is the part that was expensive.
    static func scheduled(
        on day: Date,
        for destination: ListDestination = .today,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> [Todo] {
        guard let descriptor = scheduledDescriptor(on: day, calendar: calendar) else { return [] }
        return calendarScope(fetch(descriptor, in: context), for: destination)
    }

    /// A day's untimed rows, scoped to a container. See `scheduled(on:...)`.
    static func untimed(
        on day: Date,
        for destination: ListDestination = .today,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> [Todo] {
        guard let descriptor = untimedDescriptor(on: day, calendar: calendar) else { return [] }
        return calendarScope(fetch(descriptor, in: context), for: destination)
    }

    /// A day's timed rows, scoped to a container. See `scheduled(on:...)`.
    static func timed(
        on day: Date,
        for destination: ListDestination = .today,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> [Todo] {
        guard let descriptor = timedDescriptor(on: day, calendar: calendar) else { return [] }
        return calendarScope(fetch(descriptor, in: context), for: destination)
    }

    /// Late work, narrowed to a container.
    static func overdue(
        for destination: ListDestination = .today,
        in context: ModelContext,
        now: Date = Date()
    ) -> [Todo] {
        calendarScope(fetch(overdueDescriptor(now: now), in: context), for: destination)
            .filterCycles()
    }

    /// The work a scoped calendar *cannot* draw: everything in the container
    /// with no date to place it on.
    static func unscheduled(
        for destination: ListDestination,
        in context: ModelContext,
        includeResolved: Bool = false
    ) -> [Todo] {
        let fetched = fetch(unscheduledDescriptor(includeResolved: includeResolved), in: context)
        return calendarScope(fetched, for: destination)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Projects with no space, for the sidebar's ungrouped section.
    static func looseProjects(in context: ModelContext) -> [Todo] {
        fetch(looseProjectsDescriptor(), in: context)
    }

    /// Today's work with no time of day attached.
    static func untimedToday(
        in context: ModelContext,
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false
    ) -> [Todo] {
        todos(
            for: .today,
            in: context,
            calendar: calendar,
            now: now,
            includeResolved: includeResolved
        )
        .filter { !$0.assignedHasTime }
    }

    // MARK: - In-memory rules
    //
    // The same destinations applied to an array the caller already holds.
    // Previews, the widget snapshot, and the tests use these; the app's views
    // go through the descriptors above.

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
            .filterTemplates()
            .filter(includeResolved: includeResolved)
            .filterResolved()
            .filterCycles()
            .sorted(by: sortByOrder)
    }


    /// Everything due or scheduled on or before today, plus anything overdue.
    ///
    /// Overdue work stays in Today so it cannot be missed by moving past its
    /// date.
    static func today(
        _ todos: [Todo],
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> [Todo] {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = startOfToday.addingTimeInterval(24 * 3600)
        // Matching `todayDescriptor`: open-ended backwards unless overdue work
        // is hidden. The two paths answer the same question and must not
        // disagree.
        let lowerBound = includeOverdue ? Date.distantPast : startOfToday

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned >= lowerBound, assigned < endOfToday { return true }
                if let due = todo.dueDate, due >= lowerBound, due < endOfToday { return true }
                return false
            }
            .filterTemplates()
            .filter(includeResolved: includeResolved)
            // The in-memory twin of `resolvedWithin` in `todayDescriptor`: the
            // backward reach above is for overdue work, so finished work is
            // held to today separately. Without it, showing completed items
            // listed the whole archive — everything ever finished is also dated
            // before the end of today.
            .filterResolved(within: startOfToday, endOfToday)
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
            .filterTemplates()
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
    static func thisWeek(
        _ todos: [Todo],
        calendar: Calendar = .current,
        now: Date = Date(),
        includeResolved: Bool = false,
        includeOverdue: Bool = true
    ) -> [Todo] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        let lowerBound = includeOverdue ? Date.distantPast : week.start

        return topLevel(todos)
            .filter { todo in
                if let assigned = todo.assignedDate, assigned >= lowerBound, assigned < week.end { return true }
                if let due = todo.dueDate, due >= lowerBound, due < week.end { return true }
                return false
            }
            .filterTemplates()
            .filter(includeResolved: includeResolved)
            // Matching `thisWeekDescriptor`, and for the same reason as Today.
            .filterResolved(within: week.start, week.end)
            .filterCycles()
            .sorted(by: sortByDateThenOrder)
    }

    /// Scheduled work with no specific home.
    static func anytime(_ todos: [Todo], includeResolved: Bool = false) -> [Todo] {
        topLevel(todos)
            .filter { $0.bucket == .anytime && !$0.isProject }
            // A dormant series shows itself here; an active one is represented
            // by its current instance instead. See `anytimeDescriptor`.
            .filter { !$0.isRecurrenceTemplate || $0.isDormantRecurrenceTemplate }
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
    ///
    /// Stays an in-memory pass even on the fetch path: `belongs`/`isDescendant`
    /// walk `ancestors` upwards to arbitrary depth, and `#Predicate` has no way
    /// to express a transitive relationship.
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

    /// `sortByOrder` as `SortDescriptor`s, so SQLite orders the rows.
    ///
    /// The resolved-last rule sorts on `stateRaw` rather than on `isResolved`,
    /// which is computed. That works only because the four raw values happen to
    /// order the way the rule wants — "cancelled"/"completed" both sort before
    /// "open"/"started" alphabetically, which is the *wrong* direction — so the
    /// column is taken in reverse to put the unresolved states first.
    private static var orderSort: [SortDescriptor<Todo>] {
        [
            SortDescriptor(\Todo.stateRaw, order: .reverse),
            SortDescriptor(\Todo.sortIndex),
            SortDescriptor(\Todo.createdAt),
        ]
    }

    /// `sortByDateThenOrder` as `SortDescriptor`s.
    ///
    /// A *pre*-sort, not the final order. The array comparator keys on
    /// `assignedDate ?? dueDate` — a per-row choice between two columns that no
    /// `SortDescriptor` can express — and it puts undated rows last, where SQL
    /// sorts NULLs first. Callers therefore re-apply `sortByDateThenOrder` to
    /// the fetched page, which is exact and costs a sort over the rows the list
    /// actually shows rather than over the store.
    ///
    /// Kept anyway so the rows arrive close to their final order, and so a
    /// descriptor used on its own is still sensibly ordered.
    private static var dateThenOrderSort: [SortDescriptor<Todo>] {
        [
            SortDescriptor(\Todo.stateRaw, order: .reverse),
            SortDescriptor(\Todo.assignedDate),
            SortDescriptor(\Todo.dueDate),
            SortDescriptor(\Todo.sortIndex),
            SortDescriptor(\Todo.createdAt),
        ]
    }

    private static func sortByOrder(_ a: Todo, _ b: Todo) -> Bool {
        if a.state.isResolved != b.state.isResolved { return !a.state.isResolved } // if a is not resolved, it is less than b
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        return a.createdAt < b.createdAt
    }

    /// Dated items first, in date order; undated items keep manual order.
    /// Where a to-do sits in the widget's running order.
    ///
    /// The widget shows a handful of rows on a home screen, so the ones worth
    /// the space are the ones that need acting on *now*. Ranked rather than
    /// sorted by date, because "soon" and "later" are the same clock reading a
    /// few hours apart and only the bands matter.
    ///
    /// Past-scheduled work ranks last despite being the most overdue: it has
    /// already slipped, so it is a record rather than a prompt, and letting it
    /// head the list would push the day's actual next thing off the widget.
    enum WidgetRank: Int, Comparable {
        /// Timed, and its slot is open now.
        case now
        /// Timed, and starting within the hour.
        case soon
        /// Timed, later today.
        case later
        /// Today's work with no time attached.
        case unscheduled
        /// Timed, and its slot has already passed.
        case past

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How wide the "now" window is: a to-do is current from its start until
    /// its duration runs out, or for this long if it has none.
    static let widgetNowWindow: TimeInterval = 15 * 60
    /// How far ahead "soon" reaches.
    static let widgetSoonWindow: TimeInterval = 60 * 60

    /// Classify one to-do for the widget's ordering.
    static func widgetRank(for todo: Todo, now: Date = Date()) -> WidgetRank {
        // Untimed work has no slot to be early or late for. This covers items
        // that are only due-dated as well: a deadline says nothing about when
        // in the day to act, so it is not a schedule.
        guard todo.assignedHasTime, let start = todo.assignedDate else { return .unscheduled }

        let end = start.addingTimeInterval(todo.duration ?? widgetNowWindow)

        if now >= start {
            return now < end ? .now : .past
        }
        return start.timeIntervalSince(now) <= widgetSoonWindow ? .soon : .later
    }

    /// Today's work in the order the home screen widget shows it.
    ///
    /// Scheduled now, then soon, then later today, then untimed work, and
    /// finally what was scheduled earlier and has passed. Within a band the
    /// usual date-then-manual-order rule applies, so equally urgent items keep
    /// the order the user arranged them in.
    static func widgetOrdered(_ todos: [Todo], now: Date = Date()) -> [Todo] {
        todos
            .map { (todo: $0, rank: widgetRank(for: $0, now: now)) }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return sortByDateThenOrder(a.todo, b.todo)
            }
            .map(\.todo)
    }

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
