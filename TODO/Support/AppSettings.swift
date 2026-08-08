import Foundation
import SwiftUI

struct UserInfo: Codable {
    var name: String?
    var generalInfomation: String?
    var memory: String?
}

extension UserInfo {
    static var `default`: Self {
        return .init()
    }
}

/// User preferences, backed by `UserDefaults` in the app group so a future
/// widget and CLI observe the same values.
@Observable
final class AppSettings {
    #if DEBUG
    static let shared = {
        var shared = AppSettings()
        shared.userInfo = .init(name: "John")
        return shared
    }()
    #else
    static let shared = AppSettings()
    #endif

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
        static let showCalendarEvents = "showCalendarEvents"
        static let visibleCalendars = "visibleCalendars"
        static let showResolved = "showResolved"
        static let userInfo = "userInfo"
    }

    /// Whether system calendar events appear in the calendar view.
    var showCalendarEvents: Bool {
        get { defaults.object(forKey: Key.showCalendarEvents) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showCalendarEvents) }
    }

    /// Identifiers of the calendars to display. Empty means all of them.
    var visibleCalendars: [String] {
        get { defaults.stringArray(forKey: Key.visibleCalendars) ?? [] }
        set { defaults.set(newValue, forKey: Key.visibleCalendars) }
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
    
    var showResolved: Bool {
        get { defaults.object(forKey: Key.showResolved) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showResolved) }
    }
    
    var userInfo: UserInfo {
        get {
            let decoder = JSONDecoder()
            if
                let data = defaults.data(forKey: Key.userInfo),
                let userInfo = try? decoder.decode(UserInfo.self, from: data) {
                return userInfo
            } else {
                return .default
            }
        }
        set {
            let encoder = JSONEncoder()
            defaults.set(try! encoder.encode(newValue), forKey: Key.userInfo)
        }
    }
}
