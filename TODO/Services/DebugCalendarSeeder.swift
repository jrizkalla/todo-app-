#if DEBUG
import Foundation
import OSLog
import EventKit

/// Creates sample events in a scratch calendar, for verifying the calendar
/// integration in a simulator that has no events of its own.
///
/// Debug-only and never called in normal use — it runs when the app is launched
/// with `-seedCalendarEvents`.
@MainActor
enum DebugCalendarSeeder {
    private static let calendarTitle = "TODO Sample"

    /// Add a few events to today, creating the scratch calendar if needed.
    static func seed() async {
        let store = EKEventStore()

        guard (try? await store.requestFullAccessToEvents()) == true else {
            AppLog.calendar.error("Debug seeder: no calendar access")
            return
        }

        guard let calendar = resolveCalendar(in: store) else { return }

        // Don't pile up duplicates across launches.
        let dayStart = Calendar.current.startOfDay(for: Date())
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let existing = store.events(matching: store.predicateForEvents(
            withStart: dayStart, end: dayEnd, calendars: [calendar]
        ))
        guard existing.isEmpty else {
            AppLog.calendar.info("Debug seeder: events already present")
            return
        }

        let samples: [(String, Int, Int, Int)] = [
            ("Team sync", 10, 0, 60),
            ("Dentist", 13, 30, 45),
            ("Gym", 18, 0, 90),
        ]

        for (title, hour, minute, minutes) in samples {
            guard let start = Calendar.current.date(
                bySettingHour: hour, minute: minute, second: 0, of: dayStart
            ) else { continue }

            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))

            try? store.save(event, span: .thisEvent, commit: false)
        }

        do {
            try store.commit()
            AppLog.calendar.info("Debug seeder: added sample events")
        } catch {
            AppLog.calendar.error("Debug seeder commit failed: \(error, privacy: .public)")
        }
    }

    /// Add sample reminders to the Reminders app, for exercising the import
    /// flow. Runs with `-seedReminders`.
    static func seedReminders() async {
        let store = EKEventStore()

        guard (try? await store.requestFullAccessToReminders()) == true else {
            AppLog.importer.error("Debug seeder: no reminders access")
            return
        }

        guard let list = store.defaultCalendarForNewReminders() else {
            AppLog.importer.error("Debug seeder: no default reminders list")
            return
        }

        // Don't pile up duplicates across launches.
        let existing: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [list])) {
                continuation.resume(returning: $0 ?? [])
            }
        }
        guard existing.isEmpty else {
            AppLog.importer.info("Debug seeder: reminders already present")
            return
        }

        let samples: [(String, Int?)] = [
            ("Pick up dry cleaning", 1),
            ("Call the plumber", nil),
            ("Renew car registration", 5),
        ]

        for (title, dueInDays) in samples {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = title

            if let dueInDays,
               let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: Date()) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day], from: due
                )
            }

            try? store.save(reminder, commit: false)
        }

        do {
            try store.commit()
            AppLog.importer.info("Debug seeder: added sample reminders")
        } catch {
            AppLog.importer.error("Debug seeder reminders commit failed: \(error, privacy: .public)")
        }
    }

    /// Find the scratch calendar, creating it in a writable source if absent.
    private static func resolveCalendar(in store: EKEventStore) -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle

        guard let source = store.sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewEvents?.source
        else {
            AppLog.calendar.error("Debug seeder: no writable calendar source")
            return nil
        }
        calendar.source = source

        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            AppLog.calendar.error("Debug seeder: could not create calendar: \(error, privacy: .public)")
            return nil
        }
    }
}
#endif
