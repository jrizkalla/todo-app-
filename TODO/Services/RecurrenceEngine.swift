import Foundation
import SwiftData

/// Turns recurrence templates into the to-dos the user actually sees.
///
/// The rule the whole feature rests on: **a template never appears in a list; at
/// most one of its instances does.** Everything here exists to keep that true
/// as time passes and instances are completed, deleted, or rescheduled.
///
/// Generation is *idempotent* by construction. The template stores
/// `recurrenceNextDate`, the engine only ever creates an instance for exactly
/// that date, and creating one immediately advances it. So running the engine
/// twice in a row — on launch, and again a second later when a to-do is
/// completed — produces one instance, not two. That property is what lets the
/// engine be called liberally from anywhere instead of being scheduled.
///
/// `@MainActor` for the same reason `TodoStore` is: `@Model` types are not safe
/// to touch off it.
@MainActor
struct RecurrenceEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// How far ahead an occurrence is created before its date.
    ///
    /// The *next* one is materialized as soon as it is known, rather than on
    /// the morning it falls due, so a weekly task shows up in "This Week" and
    /// on the calendar before the day arrives. Without this, a Friday task
    /// would be invisible until Friday, which defeats the point of planning a
    /// week.
    ///
    /// It bounds how far forward a *single* occurrence is created — never how
    /// many. A series only ever holds one open occurrence at a time (see
    /// `generateInstances`), so a daily rule does not fill the fortnight with
    /// fourteen identical rows; it shows tomorrow's, and the day after that
    /// one is done or its date has passed.
    static let lookaheadDays = 14

    // MARK: - Generation

    /// Bring every active series up to date.
    ///
    /// Called on launch and whenever a to-do is completed. Fetching only the
    /// templates — rows with a recurrence mode set — rather than scanning every
    /// to-do keeps this cheap enough to run on both.
    @discardableResult
    func generateDueInstances(now: Date = Date(), calendar: Calendar = .current) -> [Todo] {
        var created: [Todo] = []

        for template in activeTemplates() {
            created.append(contentsOf: generateInstances(for: template, now: now, calendar: calendar))
        }

        if !created.isEmpty {
            TodoStore(context: context).save()
        }
        return created
    }

    /// Every to-do that defines a live series.
    ///
    /// The predicate tests `recurrenceModeRaw` rather than a computed property,
    /// since `#Predicate` compares stored columns. Cancelled and paused series
    /// are filtered here rather than in the loop so a store full of retired
    /// schedules costs nothing on launch.
    private func activeTemplates() -> [Todo] {
        let activeRaw = RecurrenceStatus.active.rawValue
        let descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.recurrenceModeRaw != nil && todo.recurrenceStatusRaw == activeRaw
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Materialize the series' next occurrence, if it owes one.
    ///
    /// Produces at most one to-do per call, and nothing at all while an
    /// occurrence is already open. Running it repeatedly is therefore safe and
    /// is how it is used: on launch, on foreground, and after every completion.
    @discardableResult
    func generateInstances(
        for template: Todo,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Todo] {
        guard let rule = template.recurrenceRule, rule.status.generatesInstances else { return [] }

        // A template that has never run needs a starting point.
        if template.recurrenceNextDate == nil {
            template.recurrenceNextDate = firstDate(for: template, rule: rule, now: now, calendar: calendar)
        }

        // One live occurrence at a time, in every mode.
        //
        // For the completion-driven modes this is the rule itself: the next is
        // not owed until this one is done. For `.onSchedule` it is a display
        // decision with the same shape — the series keeps running on the
        // calendar whether or not anything is ticked, but showing a daily task
        // as fourteen identical rows stretching into the fortnight is not a
        // to-do list, it is a calendar. The user sees the one that is next, and
        // the following one arrives when this one is resolved or its day has
        // gone by.
        if template.currentRecurrenceInstance != nil { return [] }

        let horizon = calendar.date(byAdding: .day, value: Self.lookaheadDays, to: now) ?? now
        var created: [Todo] = []

        // Walks forward rather than creating whatever `recurrenceNextDate`
        // happens to say, because that date can be far in the past — an app
        // left closed for a month. Each turn either creates the occurrence and
        // stops, or discards a date that has already gone by and tries the
        // next one, so the user comes back to one *current* to-do instead of a
        // stack of stale ones.
        //
        // Bounded: a rule whose `nextDate` fails to advance would otherwise
        // spin here forever. 500 covers a daily series left alone for a year.
        var guardCount = 0
        while let next = template.recurrenceNextDate, next <= horizon, guardCount < 500 {
            guardCount += 1

            let following = rule.nextDate(after: next, calendar: calendar)

            // Is this occurrence still worth showing? Anything whose day has
            // passed is skipped *unless* it is the last one the series will
            // ever produce — an overdue final occurrence is real work, and
            // dropping it would silently lose the end of the series.
            let isPast = next < calendar.startOfDay(for: now)
            if isPast, following != nil {
                template.recurrenceNextDate = following
                continue
            }

            created.append(makeInstance(of: template, on: next, rule: rule))

            guard let following else {
                // The series has run past its end date; it is finished rather
                // than merely idle, so nothing more is ever generated.
                template.recurrenceNextDate = nil
                break
            }
            template.recurrenceNextDate = following
            break
        }

        return created
    }

    /// Where a brand-new series starts.
    ///
    /// The template's own assigned date if it has one — the user picked a date
    /// and then made it repeat, so the first occurrence is that date, not one
    /// interval after it. Otherwise the rule's first fire from now.
    private func firstDate(
        for template: Todo,
        rule: RecurrenceRule,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let assigned = template.assignedDate {
            return rule.applyingTimeOfDay(to: assigned, calendar: calendar)
        }
        // Stepping from yesterday rather than now, so a rule whose day is today
        // fires today instead of skipping to the next interval.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        return rule.nextDate(after: yesterday, calendar: calendar)
    }

    /// Build one occurrence.
    ///
    /// The instance is a full copy of the template's *content* — title, notes,
    /// duration, colour, placement, and its subtask checklist — because that is
    /// what makes it behave like an ordinary to-do everywhere. It deliberately
    /// does not copy the recurrence columns: an instance that was itself a
    /// template would generate instances of its own.
    private func makeInstance(of template: Todo, on date: Date, rule: RecurrenceRule) -> Todo {
        let instance = Todo(
            title: template.title,
            notes: template.notes,
            assignedDate: date,
            assignedHasTime: rule.hasTime,
            duration: template.duration,
            dueDate: template.dueDate,
            dueHasTime: template.dueHasTime,
            space: template.space,
            parent: template.parent
        )
        instance.colorHex = template.colorHex
        instance.sortIndex = template.sortIndex
        instance.recurrenceTemplate = template
        context.insert(instance)

        // The checklist is part of what the task *is*, so each occurrence gets
        // its own copy to tick off rather than sharing — and starting fresh,
        // since last week's ticks say nothing about this week's.
        for subtask in template.orderedSubtasks {
            let copy = Todo(title: subtask.title, notes: subtask.notes)
            copy.sortIndex = subtask.sortIndex
            context.insert(copy)
            instance.addSubtask(copy)
        }

        instance.refileForCurrentScheduling()
        // A generated to-do is something arriving without the user's doing, so
        // it carries the same "new" dot an imported reminder does.
        instance.markAsNew()
        return instance
    }

    // MARK: - Completion

    /// Advance a series because one of its instances was resolved.
    ///
    /// This is the half of the feature that the calendar alone cannot do: an
    /// `.afterCompletion` rule measures its gap from *now*, and a
    /// `.afterCompletionOnSchedule` one has been holding back a date that is
    /// already due. Both become generatable at the moment a checkbox is ticked,
    /// which is why `TodoStore` calls this on every state change.
    func handleResolution(of todo: Todo, now: Date = Date(), calendar: Calendar = .current) {
        guard let template = todo.recurrenceTemplate,
              let rule = template.recurrenceRule,
              rule.status.generatesInstances
        else { return }

        switch rule.mode {
        case .afterCompletion:
            // The gap runs from the completion, so the schedule is rewritten
            // rather than continued.
            template.recurrenceNextDate = rule.nextDate(after: now, calendar: calendar)

        case .afterCompletionOnSchedule:
            // The date was already computed when the last instance was made;
            // it was simply being withheld. But if it has since gone by, roll
            // forward so the user is not handed something already overdue.
            if let next = template.recurrenceNextDate, next < calendar.startOfDay(for: now) {
                template.recurrenceNextDate = rule.nextDate(after: now, calendar: calendar)
            }

        case .onSchedule:
            // Nothing to do: these are generated by the calendar, not by
            // completion, and the next date is already set.
            break
        }

        generateInstances(for: template, now: now, calendar: calendar)
        TodoStore(context: context).save()
    }

    /// Reopening a resolved instance should not leave its successor standing.
    ///
    /// Without this, ticking and un-ticking a completion-driven task leaves two
    /// open occurrences of a series that is supposed to have one. The successor
    /// is only removed when it is untouched — same title, still open, and
    /// generated from the same template — so a successor the user has since
    /// edited is left alone.
    func handleReopening(of todo: Todo, now: Date = Date(), calendar: Calendar = .current) {
        guard let template = todo.recurrenceTemplate,
              let rule = template.recurrenceRule,
              rule.mode.waitsForCompletion
        else { return }

        let successors = template.recurrenceInstanceList.filter {
            $0.uuid != todo.uuid
                && !$0.state.isResolved
                && $0.title == template.title
                && ($0.assignedDate.map { date in date > (todo.assignedDate ?? .distantPast) } ?? false)
        }

        for successor in successors {
            // Put the schedule back where the successor was going to fire, so
            // completing again produces the same date rather than skipping one.
            template.recurrenceNextDate = successor.assignedDate
            context.delete(successor)
        }

        if !successors.isEmpty {
            TodoStore(context: context).save()
        }
    }
}
