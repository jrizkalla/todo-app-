import Foundation
import OSLog
import EventKit

/// Seam for the future export feature.
///
/// The spec lists export (manual, to Reminders, or to Calendar) as a future
/// feature. The mapping from a `Todo` to each destination lives here so that
/// building the feature is a matter of calling these methods from a UI action
/// — the model-to-EventKit translation is already settled and unit-testable.
///
/// Nothing here is wired to the UI yet.
@MainActor
struct ExportService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    // MARK: Destinations

    enum Destination {
        case reminders(listIdentifier: String?)
        case calendar(calendarIdentifier: String?)
    }

    // MARK: Mapping

    /// Build an `EKReminder` mirroring a todo.
    ///
    /// Exposed separately from the write so the mapping can be tested without
    /// touching the user's data.
    func makeReminder(from todo: Todo, in calendar: EKCalendar) -> EKReminder {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = todo.plainTitle
        reminder.notes = todo.notes.isEmpty ? nil : todo.notes
        reminder.isCompleted = todo.state == .completed

        if let due = todo.dueDate {
            reminder.dueDateComponents = Self.components(for: due, includeTime: todo.dueHasTime)
        }
        if let assigned = todo.assignedDate {
            reminder.startDateComponents = Self.components(for: assigned, includeTime: todo.assignedHasTime)
        }

        for todoReminder in todo.reminderList where todoReminder.kind == .dateTime {
            if let fireDate = todoReminder.fireDate {
                reminder.addAlarm(EKAlarm(absoluteDate: fireDate))
            }
        }

        return reminder
    }

    /// Build an `EKEvent` for a scheduled todo.
    ///
    /// Returns nil for a todo with no assigned date, which has no place on a
    /// calendar.
    func makeEvent(
        from todo: Todo,
        in calendar: EKCalendar,
        defaultDuration: TimeInterval
    ) -> EKEvent? {
        guard let start = todo.assignedDate else { return nil }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = todo.plainTitle
        event.notes = todo.notes.isEmpty ? nil : todo.notes
        event.startDate = start

        // An untimed todo becomes an all-day event; a timed one uses its
        // duration, falling back to the configured default.
        if todo.assignedHasTime {
            event.endDate = start.addingTimeInterval(todo.effectiveDuration(defaultDuration: defaultDuration))
        } else {
            event.isAllDay = true
            event.endDate = start.addingTimeInterval(24 * 3600)
        }

        return event
    }

    private static func components(for date: Date, includeTime: Bool) -> DateComponents {
        let fields: Set<Calendar.Component> = includeTime
            ? [.year, .month, .day, .hour, .minute]
            : [.year, .month, .day]
        return Calendar.current.dateComponents(fields, from: date)
    }

    // MARK: Markdown

    /// Plain-text/markdown rendering for the manual export option.
    static func markdown(for todos: [Todo]) -> String {
        todos.map { markdownLine(for: $0, depth: 0) }.joined(separator: "\n")
    }

    private static func markdownLine(for todo: Todo, depth: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        let box = todo.state.isResolved ? "x" : " "
        var line = "\(indent)- [\(box)] \(todo.title)"

        if let due = todo.dueDate {
            line += " (due \(due.formatted(date: .abbreviated, time: todo.dueHasTime ? .shortened : .omitted)))"
        }

        let children = todo.orderedSubtasks
            .map { markdownLine(for: $0, depth: depth + 1) }
            .joined(separator: "\n")

        return children.isEmpty ? line : "\(line)\n\(children)"
    }
}
