import Foundation
import OSLog

/// Shared loggers. Subsystem matches the bundle id so Console filtering works.
///
/// `nonisolated` so delegate callbacks that arrive off the main actor — such as
/// CoreLocation's region events — can log without hopping actors. `Logger` is
/// `Sendable` and these are immutable.
nonisolated enum AppLog {
    private static let subsystem = "com.johnrizkalla.app.TODO"

    static let data = Logger(subsystem: subsystem, category: "data")
    static let importer = Logger(subsystem: subsystem, category: "importer")
    static let reminders = Logger(subsystem: subsystem, category: "reminders")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
