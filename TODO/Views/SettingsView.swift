import SwiftUI
import SwiftData
import EventKit

/// App preferences: the calendar default, Reminders import, and — on macOS —
/// vim bindings.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @State private var importer = RemindersImporter.shared
    @State private var availableLists: [EKCalendar] = []
    @State private var isImporting = false
    @State private var statusMessage: String?

    @State private var calendarStore = CalendarEventStore.shared
    @State private var availableCalendars: [EKCalendar] = []

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Calendar") {
                Picker("Default duration", selection: Binding(
                    get: { settings.defaultEventDuration },
                    set: { settings.defaultEventDuration = $0 }
                )) {
                    ForEach([300.0, 600.0, 900.0, 1800.0, 3600.0], id: \.self) { seconds in
                        Text(ParsedSuggestion.describe(duration: seconds)).tag(seconds)
                    }
                }
                .help("Length used for timed to-dos that have no duration of their own.")

                Toggle("Week starts on Monday", isOn: $settings.weekStartsOnMonday)
                Toggle("Show Inbox & overdue panel", isOn: $settings.showSidePanel)
            }

            #if os(macOS)
            Section("Editing") {
                Toggle("Vim key bindings in text fields", isOn: $settings.vimBindingsEnabled)
                Text("Adds normal, insert, and visual modes to the notes editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section {
                Toggle("Scan Reminders on launch", isOn: $settings.remindersImportEnabled)

                Text("Reminders from these lists appear in your Inbox, where you can import them one at a time or all at once. A reminder is removed from the Reminders app only when you import it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.remindersImportEnabled {
                    if availableLists.isEmpty {
                        Button("Grant Access to Reminders") {
                            Task {
                                if await importer.requestAccess() {
                                    availableLists = importer.availableLists()
                                }
                            }
                        }
                    } else {
                        // Empty selection means every list, so the UI states
                        // that explicitly rather than looking like a no-op.
                        Text(settings.importReminderLists.isEmpty
                             ? "Scanning all lists"
                             : "Scanning \(settings.importReminderLists.count) list(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(availableLists, id: \.calendarIdentifier) { list in
                            Toggle(list.title, isOn: Binding(
                                get: {
                                    settings.importReminderLists.isEmpty
                                        || settings.importReminderLists.contains(list.calendarIdentifier)
                                },
                                set: { enabled in
                                    var selected = settings.importReminderLists.isEmpty
                                        ? availableLists.map(\.calendarIdentifier)
                                        : settings.importReminderLists
                                    if enabled {
                                        if !selected.contains(list.calendarIdentifier) {
                                            selected.append(list.calendarIdentifier)
                                        }
                                    } else {
                                        selected.removeAll { $0 == list.calendarIdentifier }
                                    }
                                    settings.importReminderLists = selected
                                }
                            ))
                        }

                        Button(isImporting ? "Checking…" : "Check Now") {
                            runScan()
                        }
                        .disabled(isImporting)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reminders Import")
            }

            Section {
                Toggle("Show calendar events", isOn: $settings.showCalendarEvents)

                Text("Displays events from your calendars alongside to-dos in the calendar view. TODO never changes your calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.showCalendarEvents {
                    if availableCalendars.isEmpty {
                        Button("Grant Access to Calendars") {
                            Task {
                                if await calendarStore.requestAccess() {
                                    availableCalendars = calendarStore.availableCalendars()
                                }
                            }
                        }
                    } else {
                        // Empty selection means every calendar, so say so rather
                        // than showing what looks like nothing selected.
                        Text(settings.visibleCalendars.isEmpty
                             ? "Showing all calendars"
                             : "Showing \(settings.visibleCalendars.count) calendar(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: Binding(
                                get: {
                                    settings.visibleCalendars.isEmpty
                                        || settings.visibleCalendars.contains(calendar.calendarIdentifier)
                                },
                                set: { enabled in
                                    var selected = settings.visibleCalendars.isEmpty
                                        ? availableCalendars.map(\.calendarIdentifier)
                                        : settings.visibleCalendars
                                    if enabled {
                                        if !selected.contains(calendar.calendarIdentifier) {
                                            selected.append(calendar.calendarIdentifier)
                                        }
                                    } else {
                                        selected.removeAll { $0 == calendar.calendarIdentifier }
                                    }
                                    settings.visibleCalendars = selected
                                }
                            )) {
                                Label {
                                    Text(calendar.title)
                                } icon: {
                                    Circle()
                                        .fill(Color(hex: CalendarEventStore.hexString(from: calendar.cgColor)))
                                        .frame(width: 10, height: 10)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Calendar Events")
            }

            Section("Sync") {
                LabeledContent("iCloud", value: "Automatic")
                Text("To-dos sync across your devices through your iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .navigationTitle("Settings")
        .task {
            if importer.hasAccess {
                availableLists = importer.availableLists()
            }
            if calendarStore.hasAccess {
                availableCalendars = calendarStore.availableCalendars()
            }
        }
        // Access may be granted from the calendar view rather than here, so the
        // list refreshes when the toggle is switched on instead of only at
        // first appearance.
        .task(id: settings.showCalendarEvents) {
            guard settings.showCalendarEvents, availableCalendars.isEmpty else { return }

            var granted = calendarStore.hasAccess
            if !granted {
                granted = await calendarStore.requestAccess()
            }
            if granted {
                availableCalendars = calendarStore.availableCalendars()
            }
        }
    }

    /// Refresh the pending list. Read-only — importing happens in the Inbox.
    private func runScan() {
        isImporting = true
        Task {
            await importer.scan(
                listIdentifiers: settings.importReminderLists,
                context: context
            )
            let count = importer.pending.count
            statusMessage = count == 0
                ? "No new reminders waiting."
                : "\(count) reminder\(count == 1 ? "" : "s") waiting in your Inbox."
            isImporting = false
        }
    }
}
