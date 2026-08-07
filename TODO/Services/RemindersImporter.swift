import Foundation
import OSLog
import EventKit
import SwiftData

/// Imports items from the system Reminders app into the Inbox.
///
/// Per the spec, imported reminders are removed from the Reminders app. Each
/// deletion happens only after the corresponding todo has been saved to the
/// store, so a failure mid-import can never lose a reminder without having
/// created its replacement.
@MainActor
final class RemindersImporter {
    private let eventStore = EKEventStore()

    struct ImportResult {
        var imported: Int = 0
        var skipped: Int = 0
        var failedDeletions: Int = 0
    }

    // MARK: Access

    /// Request full access, which is required to read and delete reminders.
    func requestAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToReminders()
        } catch {
            AppLog.importer.error("Reminders access failed: \(error, privacy: .public)")
            return false
        }
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Lists the user can choose between in settings.
    func availableLists() -> [EKCalendar] {
        guard hasAccess else { return [] }
        return eventStore.calendars(for: .reminder)
    }

    // MARK: Import

    /// Scan the configured lists and import everything not already imported.
    ///
    /// - Parameter listIdentifiers: Which lists to scan; empty means all.
    @discardableResult
    func importReminders(
        from listIdentifiers: [String],
        into context: ModelContext
    ) async -> ImportResult {
        guard hasAccess else { return ImportResult() }

        let calendars = resolveCalendars(listIdentifiers)
        guard !calendars.isEmpty else { return ImportResult() }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let ekReminders: [EKReminder] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        // Ids already in the store, so a rescan never duplicates.
        let existing = Set(
            ((try? context.fetch(FetchDescriptor<Todo>())) ?? [])
                .compactMap(\.sourceReminderID)
        )

        let store = TodoStore(context: context)
        var result = ImportResult()

        for ekReminder in ekReminders {
            guard !ekReminder.isCompleted else { continue }
            guard !existing.contains(ekReminder.calendarItemIdentifier) else {
                result.skipped += 1
                continue
            }

            let todo = makeTodo(from: ekReminder)
            context.insert(todo)

            // Persist before deleting the source, so the reminder is never
            // removed without its replacement being safely stored.
            do {
                try context.save()
            } catch {
                AppLog.importer.error("Import save failed, keeping source reminder: \(error, privacy: .public)")
                context.delete(todo)
                continue
            }

            result.imported += 1

            do {
                try eventStore.remove(ekReminder, commit: false)
            } catch {
                result.failedDeletions += 1
                AppLog.importer.error("Could not delete source reminder: \(error, privacy: .public)")
            }
        }

        // Commit the batch of deletions once at the end.
        if result.imported > 0 {
            do {
                try eventStore.commit()
            } catch {
                AppLog.importer.error("Commit of reminder deletions failed: \(error, privacy: .public)")
            }
        }

        store.save()
        AppLog.importer.info("Imported \(result.imported) reminders, skipped \(result.skipped)")
        return result
    }

    /// Build a todo carrying across as much of the reminder as maps cleanly.
    private func makeTodo(from ekReminder: EKReminder) -> Todo {
        let todo = Todo(title: ekReminder.title ?? "")
        todo.notes = ekReminder.notes ?? ""
        todo.importedFromReminders = true
        todo.sourceReminderID = ekReminder.calendarItemIdentifier

        // Reminders' due date maps to the deadline, and its "has time" flag
        // follows whether the components carry an hour.
        if let due = ekReminder.dueDateComponents {
            todo.dueDate = Calendar.current.date(from: due)
            todo.dueHasTime = due.hour != nil
        }

        // A start date, if present, is the day the user planned to act.
        if let start = ekReminder.startDateComponents {
            todo.assignedDate = Calendar.current.date(from: start)
            todo.assignedHasTime = start.hour != nil
        }

        // Carry alarms across as reminders so alerts survive the move.
        for alarm in ekReminder.alarms ?? [] {
            if let absolute = alarm.absoluteDate {
                let reminder = Reminder(kind: .dateTime, fireDate: absolute, todo: todo)
                todo.reminders = (todo.reminders ?? []) + [reminder]
            } else if let structured = alarm.structuredLocation, let location = structured.geoLocation {
                let reminder = Reminder(
                    kind: .location,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radius: structured.radius > 0 ? structured.radius : 100,
                    placeName: structured.title,
                    trigger: alarm.proximity == .leave ? .onDeparture : .onArrival,
                    todo: todo
                )
                todo.reminders = (todo.reminders ?? []) + [reminder]
            }
        }

        // Imported items start unscheduled in the Inbox unless the reminder
        // carried a date, which the spec's filing rule then promotes.
        todo.refileForCurrentScheduling()
        return todo
    }

    private func resolveCalendars(_ identifiers: [String]) -> [EKCalendar] {
        let all = eventStore.calendars(for: .reminder)
        guard !identifiers.isEmpty else { return all }
        return all.filter { identifiers.contains($0.calendarIdentifier) }
    }
}
