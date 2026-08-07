import Foundation

/// Lifecycle of a todo. Stored as a raw `String` so CloudKit sees a primitive
/// and so new cases can be added without a migration.
enum CompletionState: String, Codable, CaseIterable, Sendable {
    case open
    case started
    case cancelled
    case completed

    /// `cancelled` and `completed` both take an item out of active lists.
    var isResolved: Bool { self == .cancelled || self == .completed }

    /// Drives the checkbox glyph in list rows.
    var symbolName: String {
        switch self {
        case .open: "square"
        case .started: "square.lefthalf.filled"
        case .cancelled: "xmark.square"
        case .completed: "checkmark.square.fill"
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .started: "Started"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        }
    }
}

/// Where a todo sits when it has no explicit space.
///
/// The spec defines three buckets: `Inbox` for anything unorganized, `Anytime`
/// for scheduled-but-unfiled work, and user-created spaces. A todo in a space
/// carries a `space` relationship instead and reports `.space` here.
enum Bucket: String, Codable, CaseIterable, Sendable {
    case inbox
    case anytime
    case space

    var label: String {
        switch self {
        case .inbox: "Inbox"
        case .anytime: "Anytime"
        case .space: "Space"
        }
    }
}

/// A reminder is either a point in time or a place. Modeled as a single type
/// with a discriminator rather than a class hierarchy, because CloudKit-backed
/// SwiftData does not support abstract entities.
enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case dateTime
    case location
}

/// Whether a location reminder fires when arriving or leaving.
enum LocationTrigger: String, Codable, CaseIterable, Sendable {
    case onArrival
    case onDeparture

    var label: String {
        switch self {
        case .onArrival: "Arriving"
        case .onDeparture: "Leaving"
        }
    }
}
