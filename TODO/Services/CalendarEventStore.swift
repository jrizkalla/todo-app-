import Foundation
import OSLog
import EventKit
import SwiftUI

/// A system calendar event, flattened out of EventKit.
///
/// The calendar view renders this rather than `EKEvent` directly so the view
/// has no EventKit dependency and the type stays `Sendable` and comparable.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    /// The owning calendar's color, so events look like they do in Calendar.app.
    let colorHex: String
    let location: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Reads events from the system calendars.
///
/// Read-only by design: the app shows the user's existing schedule alongside
/// to-dos, but never writes to their calendars. Writing is left to the
/// not-yet-wired `ExportService`.
@MainActor
@Observable
final class CalendarEventStore {
    static let shared = CalendarEventStore()

    private let eventStore = EKEventStore()

    /// Events for the currently displayed range.
    private(set) var events: [CalendarEvent] = []
    /// Set when access has been checked at least once, so the UI can tell
    /// "no events" from "not asked yet".
    private(set) var didCheckAccess = false

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Request read access to the user's calendars.
    @discardableResult
    func requestAccess() async -> Bool {
        defer { didCheckAccess = true }
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            AppLog.calendar.error("Calendar access failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Calendars the user can choose between in settings.
    func availableCalendars() -> [EKCalendar] {
        guard hasAccess else { return [] }
        return eventStore.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Load events between two dates from the enabled calendars.
    ///
    /// - Parameter calendarIdentifiers: Which calendars to read; empty means
    ///   all of them, matching how the Reminders import treats its list filter.
    func loadEvents(from start: Date, to end: Date, calendarIdentifiers: [String]) {
        guard hasAccess else {
            events = []
            return
        }

        let calendars = resolveCalendars(calendarIdentifiers)
        guard !calendars.isEmpty else {
            events = []
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        events = eventStore.events(matching: predicate).map(Self.makeEvent)
    }

    /// Drop loaded events, used when the user turns the integration off.
    func clear() {
        events = []
    }

    private func resolveCalendars(_ identifiers: [String]) -> [EKCalendar] {
        let all = eventStore.calendars(for: .event)
        guard !identifiers.isEmpty else { return all }
        return all.filter { identifiers.contains($0.calendarIdentifier) }
    }

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            // `eventIdentifier` repeats across occurrences of a recurring event,
            // so the start date is folded in to keep ids unique per occurrence.
            id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "Untitled Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            colorHex: hexString(from: event.calendar.cgColor),
            location: event.location
        )
    }

    /// Convert a calendar's `CGColor` to the `#RRGGBB` form the app uses.
    static func hexString(from color: CGColor?) -> String {
        guard let components = color?.components, components.count >= 3 else { return "#8E8E93" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
