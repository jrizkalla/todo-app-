import Foundation
import SwiftData
import SwiftUI
import WidgetKit

/// The day reduced to what a glance-sized widget can show: a count, and one
/// title.
///
/// Shared by the progress widget and the lock screen's inline line rather than
/// each loading its own, because the two are visible at the same moment on the
/// same device. Two loaders would be two chances to disagree about which task
/// is next, and a lock screen that names one task above the clock while the
/// home screen names another is the app contradicting itself.
struct GlanceEntry: TimelineEntry {
    let date: Date

    /// Today's finished work, and everything the day holds.
    let done: Int
    let total: Int

    /// The next thing to do, or `nil` when the day holds nothing open.
    let next: TodoSnapshot?

    /// Whether the shared store could not be opened — the one failure the user
    /// can act on, by launching the app once.
    let isUnavailable: Bool

    /// Everything on the list is resolved. Distinct from an *empty* day: one
    /// has been finished, the other never had anything on it, and a ring that
    /// reads "full" is only earned by the first.
    var isComplete: Bool { total > 0 && done == total }

    /// Nothing is scheduled or due at all.
    var isEmpty: Bool { total == 0 }

    /// Finished share of the day, in `0...1`.
    ///
    /// An empty day reads as zero rather than dividing by one it does not have.
    /// The ring shows nothing in that case — see `ProgressRing` — so the value
    /// only has to be in range, not meaningful.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// How many are still open.
    var remaining: Int { max(total - done, 0) }

    static let placeholder = GlanceEntry(
        date: .now,
        done: 3,
        total: 5,
        next: .init(id: UUID(), title: "Standup", time: "9:30 AM", colorHex: nil),
        isUnavailable: false
    )
}

extension GlanceEntry {
    /// Read today's progress and next task out of the shared store.
    ///
    /// Fetched with `includeResolved: true`, unlike the list widget: the whole
    /// point here is the fraction, and a fetch that hides finished work can
    /// only ever report zero done. `TodoQueries.widgetProgress` and
    /// `widgetNextUp` then split that one list into the two numbers and the one
    /// title, which is what keeps the denominator and the named task describing
    /// the same day.
    @MainActor
    static func load(now: Date = Date()) -> GlanceEntry {
        guard let container = try? ModelContainer.widgetContainer() else {
            return GlanceEntry(
                date: now, done: 0, total: 0, next: nil, isUnavailable: true
            )
        }

        let todos = TodoQueries.todos(
            for: .today,
            in: container.mainContext,
            now: now,
            includeResolved: true
        )

        let progress = TodoQueries.widgetProgress(todos)
        let next = TodoQueries.widgetNextUp(todos, now: now)

        return GlanceEntry(
            date: now,
            done: progress.done,
            total: progress.total,
            next: next.map { todo in
                TodoSnapshot(
                    id: todo.uuid,
                    title: todo.title.isEmpty ? "Untitled" : todo.title,
                    time: todo.assignedHasTime && todo.assignedDate != nil
                        ? todo.assignedDate!.formatted(date: .omitted, time: .shortened)
                        : nil,
                    colorHex: todo.resolvedColorHex
                )
            },
            isUnavailable: false
        )
    }

    /// When a glance widget's contents stop being true on their own.
    ///
    /// Two things move without anyone editing anything: the day rolls over at
    /// midnight, and the next task changes when the current one's slot runs
    /// out. Waking at the earlier of those keeps the named task honest without
    /// polling — every *edit* already reloads these timelines explicitly.
    @MainActor
    static func nextRefresh(after now: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(24 * 3600))

        guard let container = try? ModelContainer.widgetContainer() else { return midnight }

        let todos = TodoQueries.todos(for: .today, in: container.mainContext, now: now)

        // The moment each timed item stops being "upcoming" — the one boundary
        // that can promote a different task to the head of the list.
        let boundaries = todos.compactMap { todo -> Date? in
            guard todo.assignedHasTime, let start = todo.assignedDate else { return nil }
            return start.addingTimeInterval(todo.duration ?? TodoQueries.widgetNowWindow)
        }

        let nextBoundary = boundaries.filter { $0 > now }.min()
        return min(nextBoundary ?? midnight, midnight)
    }
}
