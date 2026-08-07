import Foundation
import SwiftData

/// An alert attached to a todo: either a date and time, or a location.
///
/// Both variants live in one entity with a `kind` discriminator, since
/// CloudKit-backed SwiftData has no abstract-entity support. Fields belonging
/// to the other variant stay nil.
@Model
final class Reminder {
    var uuid: UUID = UUID()
    var kindRaw: String = ReminderKind.dateTime.rawValue

    // MARK: Date/time variant
    var fireDate: Date?

    // MARK: Location variant
    var latitude: Double?
    var longitude: Double?
    /// Geofence radius in meters.
    var radius: Double = 100
    /// Human-readable place name shown in the UI.
    var placeName: String?
    var triggerRaw: String = LocationTrigger.onArrival.rawValue

    /// False once the alert has fired, so a rescan does not re-register it.
    var isActive: Bool = true
    var createdAt: Date = Date()

    var todo: Todo?

    init(
        kind: ReminderKind = .dateTime,
        fireDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double = 100,
        placeName: String? = nil,
        trigger: LocationTrigger = .onArrival,
        todo: Todo? = nil
    ) {
        self.uuid = UUID()
        self.kindRaw = kind.rawValue
        self.fireDate = fireDate
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.placeName = placeName
        self.triggerRaw = trigger.rawValue
        self.todo = todo
        self.createdAt = Date()
    }
}

extension Reminder {
    var kind: ReminderKind {
        get { ReminderKind(rawValue: kindRaw) ?? .dateTime }
        set { kindRaw = newValue.rawValue }
    }

    var trigger: LocationTrigger {
        get { LocationTrigger(rawValue: triggerRaw) ?? .onArrival }
        set { triggerRaw = newValue.rawValue }
    }

    /// Stable identifier used for both `UNNotificationRequest` and CoreLocation
    /// monitor names, so a reminder can be cancelled without bookkeeping.
    var scheduleIdentifier: String { uuid.uuidString }

    /// Whether the location variant has usable coordinates.
    var hasCoordinates: Bool { latitude != nil && longitude != nil }

    var summary: String {
        switch kind {
        case .dateTime:
            guard let fireDate else { return "No date" }
            return fireDate.formatted(date: .abbreviated, time: .shortened)
        case .location:
            let place = placeName ?? "Location"
            return "\(trigger.label) \(place)"
        }
    }
}
