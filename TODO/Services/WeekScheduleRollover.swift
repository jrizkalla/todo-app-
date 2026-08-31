import Foundation
import SwiftData
import os

/// Sweeps week plans the week has moved past.
///
/// Half of week scheduling costs nothing to roll over: the anchor is a date, so
/// what was "next week" on Sunday is "this week" on Monday without a single row
/// being written. See `Todo.weekAnchor`.
///
/// The other half is what this is for. A to-do the user planned for a week that
/// has now *ended* is not next week's problem and is not undated work either —
/// they said they would do it and did not. So it is given a real date on the
/// last night of that week, which puts it in the past, which is the app's
/// existing vocabulary for exactly this: it is overdue, and Today shows it
/// because Today's window reaches backwards without limit.
///
/// Expressing it as an ordinary overdue date rather than as a third state is
/// the point. Every surface already knows what to do with a past `assignedDate`
/// — the row badge, Today, the calendar, the widget's ranking — and none of
/// them needed teaching about weeks.
@MainActor
enum WeekScheduleRollover {
    /// Evening hour the swept to-do lands on.
    ///
    /// Late in the day rather than midnight, so the sweep reads as "the end of
    /// the week you had" instead of the start of a day that had not begun. It
    /// also keeps the row sorted after everything genuinely scheduled on that
    /// last day, which is where it belongs — it is what was left over.
    static let sweptHour = 21

    /// Give every expired week plan a date on the last night of its week.
    ///
    /// Idempotent, and cheap when there is nothing to do: the fetch is bounded
    /// by `weekAnchor < startOfThisWeek` in SQL, so a store with no stale
    /// anchors returns no rows. Safe to run on every launch and every
    /// foreground, which is what it does — a week can turn over while the app
    /// is backgrounded, and that is precisely when this matters.
    ///
    /// - Returns: The to-dos it swept, for tests and logging.
    @discardableResult
    static func run(
        in context: ModelContext,
        now: Date = Date(),
        calendar: Calendar? = nil
    ) -> [Todo] {
        // The app's week-start preference, matching the lists — sweeping on a
        // different week boundary than the lists query on would move a to-do a
        // day early or late, and could sweep one the lists still consider
        // current. See `WeekMath.appCalendar`.
        let calendar = calendar ?? WeekMath.appCalendar
        let currentWeekStart = WeekMath.startOfWeek(containing: now, calendar: calendar)
        let resolvedRaws = [
            CompletionState.completed.rawValue,
            CompletionState.cancelled.rawValue,
        ]

        // Resolved work is left alone deliberately. A to-do completed during
        // the week it was planned for is a success, and stamping an overdue
        // date onto it would rewrite that as a miss — in the Logbook, where the
        // record is the whole point.
        let descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                (todo.weekAnchor.flatMap { $0 < currentWeekStart } ?? false)
                    && !resolvedRaws.contains(todo.stateRaw)
            }
        )

        let stale: [Todo]
        do {
            stale = try context.fetch(descriptor)
        } catch {
            AppLog.data.error("Week rollover fetch failed: \(String(describing: error))")
            return []
        }

        guard !stale.isEmpty else { return [] }

        for todo in stale {
            sweep(todo, calendar: calendar)
        }

        do {
            try context.save()
        } catch {
            AppLog.data.error("Week rollover save failed: \(String(describing: error))")
        }

        AppLog.data.info("Week rollover swept \(stale.count) to-do(s) into overdue")
        return stale
    }

    /// Move one to-do off its expired week and onto that week's last evening.
    ///
    /// Split out so tests can drive a single row without a store, and so the
    /// date arithmetic — which is the part that is easy to get wrong at a week
    /// boundary — sits in one readable place.
    static func sweep(_ todo: Todo, calendar: Calendar? = nil) {
        guard let anchor = todo.weekAnchor else { return }
        let calendar = calendar ?? WeekMath.appCalendar

        let weekStart = WeekMath.startOfWeek(containing: anchor, calendar: calendar)
        let weekEnd = WeekMath.endOfWeek(startingAt: weekStart, calendar: calendar)
        // The last *day* of the week, not the exclusive end — `weekEnd` is
        // already the following Monday, and dating the sweep there would put it
        // inside the week the user is now in rather than the one they missed.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: weekEnd) ?? weekStart

        let evening = calendar.date(
            bySettingHour: sweptHour, minute: 0, second: 0, of: calendar.startOfDay(for: lastDay)
        ) ?? lastDay

        todo.weekAnchor = nil
        todo.assignedDate = evening
        todo.assignedHasTime = true
        todo.refileForCurrentScheduling()
        // Deliberately *not* `refreshNewFlagAfterPlacementChange()`. The
        // placement did change, but the user did not move it — the week ran
        // out. Flagging it new would greet them with a dot on work they have
        // already seen and simply not done, which reads as an arrival rather
        // than as the reminder it is. The overdue badge is what says something
        // happened here.
        todo.markAsViewed()
        todo.touch()
    }
}
