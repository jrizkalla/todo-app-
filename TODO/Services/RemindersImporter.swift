import Foundation
import OSLog
import EventKit
import SwiftData

/// A reminder found in the Reminders app that has not been imported yet.
///
/// Shown in the Inbox as a pending row so the user can see what is waiting
/// without anything being copied or deleted first.
struct PendingReminder: Identifiable, Equatable, Sendable {
    /// The source `EKReminder`'s `calendarItemIdentifier`.
    let id: String
    let title: String
    let notes: String?
    let dueDate: Date?
    let dueHasTime: Bool
    let listTitle: String
}

/// Bridges the system Reminders app into the Inbox.
///
/// The flow is deliberately two-stage: `scan` only reads, and `importReminder`
/// copies one item and then removes the original. Nothing leaves the Reminders
/// app until the user asks for that specific item, so a bad scan can never
/// destroy anything.
@MainActor
@Observable
final class RemindersImporter {
    static let shared = RemindersImporter()

    private let eventStore = EKEventStore()

    /// Reminders waiting to be imported, refreshed by `scan`.
    private(set) var pending: [PendingReminder] = []
    /// When the last successful scan finished, used to debounce foreground
    /// rescans.
    private(set) var lastScanDate: Date?

    struct ImportResult {
        var imported: Int = 0
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
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The system's default list, pre-selected when the user has not chosen.
    var defaultListIdentifier: String? {
        guard hasAccess else { return nil }
        return eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    // MARK: Scanning

    /// Refresh `pending` from the configured lists.
    ///
    /// Read-only: it never writes to the Reminders app or the store. Runs on
    /// every foreground, so it must stay cheap and side-effect free.
    ///
    /// - Parameter listIdentifiers: Which lists to scan; `nil` means the
    ///   system's default list, and empty means none.
    func scan(listIdentifiers: [String]?, context: ModelContext) async {
        guard hasAccess else {
            pending = []
            return
        }

        let calendars = resolveCalendars(listIdentifiers)
        guard !calendars.isEmpty else {
            pending = []
            return
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let found: [EKReminder] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // Anything already imported stays out of the pending list, so a
        // re-import is never offered for the same source twice.
        let alreadyImported = Set(
            ((try? context.fetch(FetchDescriptor<Todo>())) ?? [])
                .compactMap(\.sourceReminderID)
        )

        pending = found
            .filter { !$0.isCompleted && !alreadyImported.contains($0.calendarItemIdentifier) }
            .map { reminder in
                PendingReminder(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "Untitled Reminder",
                    notes: reminder.notes,
                    dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    dueHasTime: reminder.dueDateComponents?.hour != nil,
                    listTitle: reminder.calendar.title
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        lastScanDate = Date()
        AppLog.importer.info("Scan found \(self.pending.count) pending reminders")
    }

    // MARK: Importing

    /// Import one pending reminder, then delete the original.
    ///
    /// The todo is saved before the source is touched, so a failure can leave a
    /// duplicate but never a loss.
    @discardableResult
    func importReminder(id: String, into context: ModelContext) -> Bool {
        guard hasAccess,
              let ekReminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder
        else { return false }

        let todo = makeTodo(from: ekReminder)
        context.insert(todo)

        do {
            try context.save()
        } catch {
            AppLog.importer.error("Import save failed, keeping source reminder: \(error, privacy: .public)")
            context.delete(todo)
            return false
        }

        // Only now that the copy is durable does the original go.
        do {
            try eventStore.remove(ekReminder, commit: true)
        } catch {
            AppLog.importer.error("Could not delete source reminder: \(error, privacy: .public)")
        }

        pending.removeAll { $0.id == id }
        return true
    }

    /// Import everything currently pending.
    @discardableResult
    func importAll(into context: ModelContext) -> ImportResult {
        var result = ImportResult()

        for reminder in pending {
            if importReminder(id: reminder.id, into: context) {
                result.imported += 1
            } else {
                result.failedDeletions += 1
            }
        }
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

        todo.refileForCurrentScheduling()
        // An imported to-do is something the user has not seen in this app yet,
        // so it carries the new dot until they look at the list it lands in.
        todo.markAsNew()
        return todo
    }

    /// Lists to scan.
    ///
    /// `nil` means the user has never chosen, so only the system's default list
    /// is scanned. An explicitly empty array means they deselected everything
    /// and nothing should be scanned.
    private func resolveCalendars(_ identifiers: [String]?) -> [EKCalendar] {
        let all = eventStore.calendars(for: .reminder)

        guard let identifiers else {
            return eventStore.defaultCalendarForNewReminders().map { [$0] } ?? []
        }
        return all.filter { identifiers.contains($0.calendarIdentifier) }
    }
}
