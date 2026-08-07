import Foundation
import SwiftUI

/// User preferences, backed by `UserDefaults` in the app group so a future
/// widget and CLI observe the same values.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppSchema.appGroupIdentifier)
            ?? .standard
    }

    private enum Key {
        static let defaultEventDuration = "defaultEventDuration"
        static let importReminderLists = "importReminderLists"
        static let remindersImportEnabled = "remindersImportEnabled"
        static let vimBindingsEnabled = "vimBindingsEnabled"
        static let showSidePanel = "showSidePanel"
        static let weekStartsOnMonday = "weekStartsOnMonday"
    }

    /// Calendar length for a timed todo with no explicit duration. The spec
    /// calls for 15 minutes by default, configurable here.
    var defaultEventDuration: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.defaultEventDuration)
            return stored > 0 ? stored : 15 * 60
        }
        set { defaults.set(newValue, forKey: Key.defaultEventDuration) }
    }

    /// Identifiers of the Reminders lists to scan on launch. Empty means all
    /// lists are scanned.
    var importReminderLists: [String] {
        get { defaults.stringArray(forKey: Key.importReminderLists) ?? [] }
        set { defaults.set(newValue, forKey: Key.importReminderLists) }
    }

    /// Master switch for the launch-time Reminders scan.
    var remindersImportEnabled: Bool {
        get { defaults.object(forKey: Key.remindersImportEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.remindersImportEnabled) }
    }

    /// Vim keybindings in text fields. macOS only.
    var vimBindingsEnabled: Bool {
        get { defaults.bool(forKey: Key.vimBindingsEnabled) }
        set { defaults.set(newValue, forKey: Key.vimBindingsEnabled) }
    }

    /// Right-hand Inbox/overdue panel on wide layouts.
    var showSidePanel: Bool {
        get { defaults.object(forKey: Key.showSidePanel) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showSidePanel) }
    }

    var weekStartsOnMonday: Bool {
        get { defaults.bool(forKey: Key.weekStartsOnMonday) }
        set { defaults.set(newValue, forKey: Key.weekStartsOnMonday) }
    }

    /// Calendar honoring the week-start preference, used by every week view.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsOnMonday ? 2 : 1
        return calendar
    }
}
