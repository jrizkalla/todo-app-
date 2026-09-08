import SwiftUI
import SwiftData
import EventKit
import PhotosUI

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
    /// Cached alongside `availableCalendars`: reading it hits EventKit, and the
    /// form's body re-runs often enough that doing so inline showed up as the
    /// pane hitching. Loaded in the same `task`s that fill the list.
    @State private var defaultCalendarIdentifier: String?

    #if os(macOS)
    /// Drives the Mac's About-me sheet; iOS pushes instead.
    @State private var isShowingAboutMe = false
    #endif

    /// The photo being picked for the summary background, if any.
    @State private var pickedBackground: PhotosPickerItem?
    /// Bumped after a save so the swatches redraw with the new photo.
    @State private var backgroundVersion = 0

    /// Backdrop behind the AI summary: a row of gradient swatches, plus the
    /// user's own photo.
    @ViewBuilder
    private var backgroundSection: some View {
        @Bindable var settings = settings

        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SummaryBackground.builtIn) { background in
                        swatch(for: background) {
                            SummaryBackgroundView(background: background, fillsScreen: false)
                        }
                    }

                    swatch(for: .custom) {
                        if SummaryBackgroundStore.hasImage {
                            SummaryBackgroundView(
                                background: .custom,
                                customImageData: SummaryBackgroundStore.load(),
                                fillsScreen: false
                            )
                        } else {
                            ZStack {
                                Rectangle().fill(.quaternary)
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .id(backgroundVersion)
                }
                .padding(.vertical, 4)
            }

            PhotosPicker(
                selection: $pickedBackground,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(
                    SummaryBackgroundStore.hasImage ? "Change Photo…" : "Choose Photo…",
                    systemImage: "photo.on.rectangle"
                )
            }

            if SummaryBackgroundStore.hasImage {
                Button("Remove Photo", role: .destructive) {
                    SummaryBackgroundStore.clear()
                    if settings.summaryBackground == .custom {
                        settings.summaryBackground = .dawn
                    }
                    backgroundVersion += 1
                }
            }
        } header: {
            Text("Summary Background")
        } footer: {
            Text("The backdrop behind your daily summary.")
        }
        .onChange(of: pickedBackground) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      SummaryBackgroundStore.save(data)
                else { return }

                settings.summaryBackground = .custom
                backgroundVersion += 1
                pickedBackground = nil
            }
        }
    }

    /// One selectable background thumbnail.
    private func swatch<Preview: View>(
        for background: SummaryBackground,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        let isSelected = settings.summaryBackground == background

        return Button {
            settings.summaryBackground = background
        } label: {
            VStack(spacing: 4) {
                preview()
                    .frame(width: 56, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : .clear,
                                lineWidth: 2.5
                            )
                    }

                Text(background.title)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(background.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }


    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("About me") {
                // Same platform split as the source pickers: a push on iOS,
                // a sheet on the Mac, where the Settings scene has no stack.
                #if os(macOS)
                Button("Personalize AI Summary") {
                    isShowingAboutMe = true
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingAboutMe) {
                    NavigationStack {
                        aboutMeView
                            .navigationTitle("Personalize AI Summary")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isShowingAboutMe = false }
                                }
                            }
                    }
                    .frame(minWidth: 420, minHeight: 320)
                }
                #else
                NavigationLink("Personalize AI Summary") {
                    aboutMeView
                }
                #endif
            }
            Section("TODOs") {
                Toggle("Show completed TODOs", isOn: $settings.showResolved)

                // The default for Today and This Week. Each list can still
                // override it from its own toolbar for the session.
                Toggle("Show overdue TODOs in Today", isOn: $settings.showOverdue)
            }

            backgroundSection
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

                Picker("Arrow key step", selection: $settings.calendarNudgeMinutes) {
                    ForEach(Self.nudgeChoices, id: \.self) { minutes in
                        Text(Self.minutesLabel(minutes)).tag(minutes)
                    }
                }
                .help("How far the arrow keys move or resize the selected block.")

                Picker("With Shift held", selection: $settings.calendarFineNudgeMinutes) {
                    ForEach(Self.nudgeChoices, id: \.self) { minutes in
                        Text(Self.minutesLabel(minutes)).tag(minutes)
                    }
                }
                .help("The finer step, for lining a block up exactly.")
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
                        SourceSelectionRow(
                            label: "Lists",
                            title: "Lists",
                            footer: "Reminders in the selected lists appear in your Inbox, ready to import.",
                            sources: availableLists,
                            defaultIdentifier: importer.defaultListIdentifier,
                            selection: $settings.importReminderLists
                        )

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
                                    defaultCalendarIdentifier = calendarStore.defaultCalendarIdentifier
                                }
                            }
                        }
                    } else {
                        SourceSelectionRow(
                            label: "Calendars",
                            title: "Calendars",
                            footer: "Events from the selected calendars appear alongside your to-dos in Today and This Week.",
                            sources: availableCalendars,
                            defaultIdentifier: defaultCalendarIdentifier,
                            selection: $settings.visibleCalendars
                        )
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

            DataExportSection()
            
            Section("Developer") {
                Toggle("Debug mode", isOn: $settings.developerDebugMode)
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
                defaultCalendarIdentifier = calendarStore.defaultCalendarIdentifier
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
                defaultCalendarIdentifier = calendarStore.defaultCalendarIdentifier
            }
        }
    }

    /// Steps offered for the two calendar nudge settings.
    ///
    /// One list for both pickers rather than a coarse set and a fine one: which
    /// is which is the user's business — someone working in 5-minute blocks may
    /// well want plain arrows to move by 5 and Shift by 1.
    private static let nudgeChoices = [1, 5, 10, 15, 30, 60]

    private static func minutesLabel(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) min"
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
    
    private var aboutMeView: some View {
        VStack(alignment: .leading) {
            Text("Name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: .init(
                get: { settings.userInfo.name ?? "" },
                set: { name in
                    print("Setting name: \(name)")
                    settings.userInfo = .init(
                        name: name == "" ? nil : name,
                        generalInfomation: settings.userInfo.generalInfomation
                    )
                }
            ))
            
            Spacer().frame(height: 20)
            
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextField(
                "Describe yourself, your commute, any any other information you would like to feed into the model",
                text: .init(
                    get: { settings.userInfo.generalInfomation ?? "" },
                    set: { info in
                        settings.userInfo = .init(
                            name: settings.userInfo.name,
                            generalInfomation: info == "" ? nil : info
                        )
                    }
                ),
                axis: .vertical
            )
            .lineLimit(4...)
            Spacer()
        }.padding()
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}
#endif
