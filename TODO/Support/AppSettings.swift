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

    /// Every preference is a *stored* property loaded here, not a computed one
    /// reading `UserDefaults` on each access.
    ///
    /// `@Observable` only instruments stored properties: a computed preference
    /// backed by defaults notifies nobody, so changing it left every view still
    /// showing the old value until something unrelated forced a redraw. Each
    /// `didSet` writes back, so values still survive a relaunch.
    init(defaults: UserDefaults? = nil) {
        let resolved = defaults
            ?? UserDefaults(suiteName: AppSchema.appGroupIdentifier)
            ?? .standard
        self.defaults = resolved

        self.summaryBackground = Self.loadSummaryBackground(from: resolved)

        // `object(forKey:) as? Bool` rather than `bool(forKey:)` wherever the
        // default is `true`, since the latter cannot tell "never set" from
        // "set to false".
        self.showCalendarEvents = resolved.object(forKey: Key.showCalendarEvents) as? Bool ?? false
        self.visibleCalendars = resolved.stringArray(forKey: Key.visibleCalendars)
        let duration = resolved.double(forKey: Key.defaultEventDuration)
        self.defaultEventDuration = duration > 0 ? duration : 15 * 60
        let nudge = resolved.double(forKey: Key.calendarNudgeMinutes)
        self.calendarNudgeMinutes = nudge > 0 ? Int(nudge) : 30
        let fineNudge = resolved.double(forKey: Key.calendarFineNudgeMinutes)
        self.calendarFineNudgeMinutes = fineNudge > 0 ? Int(fineNudge) : 15
        self.importReminderLists = resolved.stringArray(forKey: Key.importReminderLists)
        self.remindersImportEnabled = resolved.object(forKey: Key.remindersImportEnabled) as? Bool ?? false
        self.vimBindingsEnabled = resolved.bool(forKey: Key.vimBindingsEnabled)
        self.showSidePanel = resolved.object(forKey: Key.showSidePanel) as? Bool ?? true
        self.weekStartsOnMonday = resolved.bool(forKey: Key.weekStartsOnMonday)
        self.showResolved = resolved.object(forKey: Key.showResolved) as? Bool ?? true
        // Defaults to true: overdue work is the most important thing a to-do
        // list can surface, so it has to be visible unless the user has said
        // otherwise. `object(forKey:)` rather than `bool(forKey:)` is what
        // makes that default hold — `bool` reads an absent key as false.
        self.showOverdue = resolved.object(forKey: Key.showOverdue) as? Bool ?? true

        if let data = resolved.data(forKey: Key.userInfo),
           let decoded = try? JSONDecoder().decode(UserInfo.self, from: data) {
            self.userInfo = decoded
        } else {
            self.userInfo = .default
        }
    }

    private enum Key {
        static let defaultEventDuration = "defaultEventDuration"
        static let calendarNudgeMinutes = "calendarNudgeMinutes"
        static let calendarFineNudgeMinutes = "calendarFineNudgeMinutes"
        static let importReminderLists = "importReminderLists"
        static let remindersImportEnabled = "remindersImportEnabled"
        static let vimBindingsEnabled = "vimBindingsEnabled"
        static let showSidePanel = "showSidePanel"
        static let weekStartsOnMonday = "weekStartsOnMonday"
        static let showCalendarEvents = "showCalendarEvents"
        static let visibleCalendars = "visibleCalendars"
        static let showResolved = "showResolved"
        static let showOverdue = "showOverdue"
        static let userInfo = "userInfo"
        static let summaryBackground = "summaryBackground"
        static let developerDebugMode = "developerDebugMode"
    }

    /// Backdrop behind the AI summary.
    ///
    /// Unlike the other settings here this one is *stored*, not computed
    /// straight off `UserDefaults`. `@Observable` only instruments stored
    /// properties, so a computed one backed by defaults notifies nobody: the
    /// value changes and every view showing it keeps rendering the old one.
    /// The stored property is what SwiftUI observes; `didSet` keeps defaults in
    /// step so the value still survives a relaunch.
    ///
    /// Falls back to a built-in gradient when the user has selected their own
    /// photo but the file is gone — a deleted image should change how the
    /// screen looks, not leave it blank.
    var summaryBackground: SummaryBackground {
        didSet {
            guard summaryBackground != oldValue else { return }
            defaults.set(summaryBackground.rawValue, forKey: Key.summaryBackground)
        }
    }

    /// The stored background as it was last written, resolved for a missing
    /// custom photo.
    private static func loadSummaryBackground(from defaults: UserDefaults) -> SummaryBackground {
        guard let raw = defaults.string(forKey: Key.summaryBackground),
              let background = SummaryBackground(rawValue: raw)
        else { return .dawn }

        if background == .custom && !SummaryBackgroundStore.hasImage { return .dawn }
        return background
    }

    /// Whether system calendar events appear in the calendar view.
    var showCalendarEvents: Bool {
        didSet { write(showCalendarEvents, forKey: Key.showCalendarEvents, was: oldValue) }
    }

    /// Identifiers of the calendars to display.
    ///
    /// `nil` means the user has never chosen, which falls back to the system's
    /// default calendar rather than every calendar — the old behavior pulled in
    /// birthdays, holidays, and shared calendars nobody asked for. An empty
    /// array is a real choice ("show none") and is preserved as such.
    var visibleCalendars: [String]? {
        didSet { writeOptional(visibleCalendars, forKey: Key.visibleCalendars, was: oldValue) }
    }

    /// Calendar length for a timed todo with no explicit duration. The spec
    /// calls for 15 minutes by default, configurable here.
    var defaultEventDuration: TimeInterval {
        didSet { write(defaultEventDuration, forKey: Key.defaultEventDuration, was: oldValue) }
    }

    /// How far an arrow key moves or resizes a calendar block, in minutes.
    ///
    /// Stored as minutes rather than as a `TimeInterval` because that is the
    /// unit the grid actually works in — every other snap in the calendar is
    /// expressed in minutes, and going through seconds only invited rounding
    /// between the two.
    var calendarNudgeMinutes: Int {
        didSet { write(calendarNudgeMinutes, forKey: Key.calendarNudgeMinutes, was: oldValue) }
    }

    /// The same, with Shift held: the finer step for lining a block up exactly.
    var calendarFineNudgeMinutes: Int {
        didSet { write(calendarFineNudgeMinutes, forKey: Key.calendarFineNudgeMinutes, was: oldValue) }
    }

    /// Identifiers of the Reminders lists to scan.
    ///
    /// `nil` means never chosen, which falls back to the system's default list.
    /// See `visibleCalendars` for why that beats scanning everything.
    var importReminderLists: [String]? {
        didSet { writeOptional(importReminderLists, forKey: Key.importReminderLists, was: oldValue) }
    }

    /// Master switch for the launch-time Reminders scan.
    var remindersImportEnabled: Bool {
        didSet { write(remindersImportEnabled, forKey: Key.remindersImportEnabled, was: oldValue) }
    }

    /// Vim keybindings in text fields. macOS only.
    var vimBindingsEnabled: Bool {
        didSet { write(vimBindingsEnabled, forKey: Key.vimBindingsEnabled, was: oldValue) }
    }

    /// Right-hand Inbox/overdue panel on wide layouts.
    var showSidePanel: Bool {
        didSet { write(showSidePanel, forKey: Key.showSidePanel, was: oldValue) }
    }

    var weekStartsOnMonday: Bool {
        didSet { write(weekStartsOnMonday, forKey: Key.weekStartsOnMonday, was: oldValue) }
    }

    /// Calendar honoring the week-start preference, used by every week view.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsOnMonday ? 2 : 1
        return calendar
    }

    var showResolved: Bool {
        didSet { write(showResolved, forKey: Key.showResolved, was: oldValue) }
    }

    /// Whether the date lists carry work from before today.
    ///
    /// On by default. Turning it off narrows Today to the day itself, for
    /// someone who plans a day at a time and treats a long overdue tail as
    /// noise — but the default has to be *shown*, because a missed deadline the
    /// list quietly hides is the one failure a to-do app cannot afford.
    var showOverdue: Bool {
        didSet { write(showOverdue, forKey: Key.showOverdue, was: oldValue) }
    }

    var userInfo: UserInfo {
        didSet {
            guard let data = try? JSONEncoder().encode(userInfo) else { return }
            defaults.set(data, forKey: Key.userInfo)
        }
    }
    
    var developerDebugMode: Bool = false {
        didSet {
            write(developerDebugMode, forKey: Key.developerDebugMode, was: oldValue)
        }
    }

    // MARK: Persistence

    /// Mirror a changed value into `UserDefaults`.
    private func write<Value: Equatable>(_ value: Value, forKey key: String, was oldValue: Value) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
    }

    /// As `write`, but `nil` removes the key so "never chosen" stays
    /// distinguishable from an explicit empty selection.
    private func writeOptional<Value: Equatable>(
        _ value: Value?, forKey key: String, was oldValue: Value?
    ) {
        guard value != oldValue else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    } 
}
