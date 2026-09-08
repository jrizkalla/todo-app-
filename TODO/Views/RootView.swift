import SwiftUI
import SwiftData

/// The app's top-level tabs.
enum AppTab: String, CaseIterable, Identifiable, Hashable, Codable {
    case inbox, today, lists, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .lists: "Lists"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .today: "sparkles"
        case .lists: "list.bullet"
        case .calendar: "calendar"
        }
    }
}

/// The app shell: four tabs, each with its own navigation stack.
///
/// Inbox and Today are single screens; Lists keeps the sidebar-and-detail
/// arrangement the app has always had, and Calendar owns the day/week grid. The
/// create button lives here rather than inside any one screen, so it is on
/// every tab and creates into whichever one is open.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings

    /// This window's opening state, restored by the scene. Every window keeps
    /// its own copy, which is what lets two of them sit on different lists.
    @Binding var windowState: WindowState

    /// Which tab is showing, projected onto the window's restorable state.
    private var tab: Binding<AppTab> {
        Binding(get: { windowState.tab }, set: { windowState.tab = $0 })
    }

    /// The list the Lists tab is showing, likewise restored per window.
    private var listSelection: Binding<ListDestination?> {
        Binding(get: { windowState.list }, set: { windowState.list = $0 })
    }

    @State private var selectedTodo: Todo?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// The day the Calendar tab is showing, and its scale.
    @State private var calendarAnchor = Date()
    @State private var calendarScale: CalendarView.Scale = .day

    /// Bumped to ask the open screen to create something. Each screen watches
    /// this and does whatever "new" means for it — a row in a list, a block on
    /// the calendar — which is what keeps one button correct everywhere.
    ///
    /// How many times each tab has been asked to create something.
    ///
    /// Per tab rather than one shared counter because every tab's view stays
    /// alive once visited: a single counter changes under all of them at once,
    /// and one tap creates a to-do on each. A tab's own count only ever moves
    /// when that tab is the one asking, so nothing fires on a mere tab switch.
    @State private var createRequests: [AppTab: Int] = [:]

    /// Whether a list is currently in multi-select, which withdraws the create
    /// button from the corner the action bar needs.
    @State private var multiSelect = MultiSelectPresence.shared

    private func createCount(for tab: AppTab) -> Binding<Int> {
        Binding(
            get: { createRequests[windowState.tab] ?? 0 },
            set: { createRequests[windowState.tab] = $0 }
        )
    }

    /// A to-do just captured with Cmd+N, waiting for the Inbox list to put the
    /// caret in its title.
    ///
    /// Passed down rather than acted on here because `RootView` draws no rows:
    /// only the list has the row — and therefore the text field — that focus
    /// has to land in. Cleared by whoever claims it, so a second Cmd+N is not
    /// answered by the surface that handled the first.
    @State private var capturedTodo: UUID?

    @State private var didRunLaunchTasks = false
    @State private var importer = RemindersImporter.shared

    @Environment(\.scenePhase) private var scenePhase

    /// Shortest gap between foreground rescans, so flicking in and out of the
    /// app does not re-query EventKit repeatedly.
    private let rescanDebounce: TimeInterval = 30

    var body: some View {
        #if DEBUG && DEBUG_UI
        Self._printChanges()
        #endif
        return tabs
            // Tells the menu bar which window it is acting on, so a command
            // fires in the window the user is in rather than in all of them.
            .focusedSceneValue(\.windowID, windowState.id)
            // The undo offer floats above whatever tab is open: the action that
            // raised it has usually just taken a row off the screen the user was
            // looking at, so it cannot belong to the list that lost it.
            .undoToast()
            // Cmd+N, from anywhere in the app.
            //
            // Filtered to the window the user is actually in. The notification
            // reaches every open window, and without this each one would create
            // a to-do of its own from a single keystroke.
            .onReceive(
                NotificationCenter.default.publisher(for: .createInInboxRequested)
            ) { note in
                guard WindowIdentity.isTarget(note, self.windowState.id) else { return }
                captureIntoInbox()
            }
    }

    /// Answer Cmd+N: put a new to-do in the Inbox and show it, ready to type.
    ///
    /// The creating is done here rather than delegated to a list, so the
    /// shortcut works on the Today tab too — a screen with no list of its own,
    /// where the + button is deliberately absent. Showing the Inbox afterwards
    /// is not incidental: a row created onto a screen the user cannot see is a
    /// to-do they have no way to name.
    private func captureIntoInbox() {
        let created = TodoStore(context: context).createTodo()
        windowState.tab = .inbox
        capturedTodo = created.uuid
    }

    private var tabs: some View {
        TabView(selection: tab) {
            Tab(AppTab.inbox.title, systemImage: AppTab.inbox.symbol, value: AppTab.inbox) {
                NavigationStack {
                    TodoListView(
                        destination: .inbox,
                        selectedTodo: $selectedTodo,
                        createRequest: createCount(for: .inbox),
                        capturedTodo: $capturedTodo
                    )
                    .todoDetailDestination(selection: $selectedTodo)
                }
            }

            Tab(AppTab.today.title, systemImage: AppTab.today.symbol, value: AppTab.today) {
                NavigationStack {
                    AISummaryView(
                        onOpenSchedule: {
                            calendarAnchor = Date()
                            calendarScale = .day
                            windowState.tab = .calendar
                        },
                        onOpenAnyTime: {
                            windowState.list = .today
                            windowState.tab = .lists
                        }
                    )
                }
            }

            Tab(AppTab.lists.title, systemImage: AppTab.lists.symbol, value: AppTab.lists) {
                listsTab
            }

            Tab(AppTab.calendar.title, systemImage: AppTab.calendar.symbol, value: AppTab.calendar) {
                NavigationStack {
                    CalendarView(
                        selectedTodo: $selectedTodo,
                        destination: .today,
                        anchorDate: $calendarAnchor,
                        scaleBinding: $calendarScale,
                        createRequest: createCount(for: .calendar)
                    )
                    .todoDetailDestination(selection: $selectedTodo)
                }
            }
        }
        // One create button for the whole app, floating above the tab bar.
        //
        // The Today tab is the exception: it is a read-only glance whose two
        // cards lead somewhere else, so there is nothing there for "new" to
        // mean. Every other tab handles the request itself.
        .overlay(alignment: .bottomTrailing) {
            // Also withdrawn while a list is in multi-select: the button sits
            // in the corner the action bar occupies, and "new to-do" is not an
            // action on a selection. See `MultiSelectPresence`.
            if windowState.tab != .today && !multiSelect.isActive {
                CreateButton {
                    createRequests[windowState.tab, default: 0] += 1
                }
                .padding(.bottom, Theme.Metrics.createButtonTabBarClearance)
                // Scales out of the corner it sits in rather than blinking, so
                // arriving on Today reads as the button leaving.
                .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.panel, value: windowState.tab)
        .animation(Theme.Animation.panel, value: multiSelect.isActive)
        .task {
            guard !didRunLaunchTasks else { return }
            didRunLaunchTasks = true
            await runLaunchTasks()
        }
        // Returning to the app re-scans, so reminders added elsewhere while it
        // was backgrounded show up without a relaunch.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, didRunLaunchTasks else { return }

            // A day can turn over while the app is backgrounded, which is
            // exactly when a daily series falls due. Generation is idempotent,
            // so running it on every foreground costs a fetch and cannot
            // produce a duplicate.
            RecurrenceEngine(context: context).generateDueInstances()

            // And a *week* can turn over while it is backgrounded, which is the
            // only moment week plans need anything done to them. Idempotent for
            // the same reason: the sweep clears the anchor it acted on, so a
            // second run finds nothing.
            WeekScheduleRollover.run(in: context)

            if let last = importer.lastScanDate,
               Date().timeIntervalSince(last) < rescanDebounce {
                return
            }

            Task { await scanReminders() }
        }
    }

    /// Lists: the sidebar of spaces and projects, with the selected list beside
    /// or pushed from it.
    ///
    /// Inbox is deliberately absent from the sidebar here — it has its own tab,
    /// and listing it twice would leave two ways to reach one screen with no
    /// way to tell which one the user is on.
    private var listsTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: listSelection, selectedTodo: $selectedTodo)
                .navigationSplitViewColumnWidth(
                    min: 200, ideal: Theme.Metrics.sidebarWidth, max: 320
                )
        } detail: {
            NavigationStack {
                TodoListView(
                    destination: windowState.list ?? .today,
                    selectedTodo: $selectedTodo,
                    createRequest: createCount(for: .lists)
                )
                .frame(maxWidth: .infinity)
                .todoDetailDestination(selection: $selectedTodo)
            }
        }
    }

    /// Launch work: notification permission, rescheduling reminders, and the
    /// optional Reminders scan.
    private func runLaunchTasks() async {
        // `-skipPermissionPrompts` lets UI verification run without system
        // alerts covering the interface. Never set in normal use.
        let skipsPrompts = ProcessInfo.processInfo.arguments.contains("-skipPermissionPrompts")

        #if DEBUG
        // Spaces, projects, and dated work in the real store, so the app can be
        // driven on a device without hand-entering a fixture first.
        if ProcessInfo.processInfo.arguments.contains("-seedSampleData") {
            PreviewData.seedIfEmpty(into: context)
        }
        if ProcessInfo.processInfo.arguments.contains("-seedCalendarEvents") {
            await DebugCalendarSeeder.seed()
        }
        if ProcessInfo.processInfo.arguments.contains("-seedReminders") {
            await DebugCalendarSeeder.seedReminders()
        }
        // `-startInCalendar` opens straight into the calendar, for UI checks.
        if ProcessInfo.processInfo.arguments.contains("-startInCalendar") {
            windowState.tab = .calendar
        }
        // Likewise for Lists, the tab with the sidebar beside the list — the
        // arrangement worth looking at when the shell's chrome changes.
        if ProcessInfo.processInfo.arguments.contains("-startInLists") {
            windowState.tab = .lists
        }
        #endif

        // Materialize whatever the recurring series owe.
        //
        // Before the reminder work below, and before the first list is drawn:
        // an instance due today has to exist by the time Today renders, or the
        // user sees an empty list that fills in a moment later.
        RecurrenceEngine(context: context).generateDueInstances()

        // Then settle up last week's plans, for the same reason and in the same
        // window: a to-do whose week ran out has to be overdue by the time
        // Today draws, not a moment after.
        WeekScheduleRollover.run(in: context)

        // Scheduling itself prompts for authorization, so both steps are gated.
        if !skipsPrompts {
            await NotificationScheduler.shared.requestNotificationAuthorization()

            let reminders = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
            await NotificationScheduler.shared.syncAll(reminders: reminders)
        }

        await scanReminders(skipsPrompts: skipsPrompts)
    }

    /// Refresh the pending-reminder list.
    ///
    /// Read-only — it only populates the Inbox's pending section, and nothing
    /// is copied or deleted until the user taps Import. That is what makes it
    /// safe to run on every foreground.
    private func scanReminders(skipsPrompts: Bool = false) async {
        guard settings.remindersImportEnabled, !skipsPrompts else { return }

        var hasAccess = importer.hasAccess
        if !hasAccess {
            hasAccess = await importer.requestAccess()
        }
        guard hasAccess else { return }

        await importer.scan(
            listIdentifiers: settings.importReminderLists,
            context: context
        )
    }
}

/// The floating "new" button, shared by every tab that can create something.
///
/// Only the appearance lives here; what a tap *means* is the open screen's
/// business, which is why this takes a bare closure.
struct CreateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: Theme.Metrics.createButtonGlyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: Theme.Metrics.createButtonSize,
                    height: Theme.Metrics.createButtonSize
                )
        }
        .buttonBorderShape(.circle)
        .buttonStyle(.glassProminent)
        .padding(.trailing, Theme.Metrics.createButtonInset)
        .padding(.bottom, Theme.Metrics.createButtonInset)
        .accessibilityLabel("New To-Do")
        // No keyboard shortcut of its own. Cmd+N is the Inbox capture command
        // — see `AppCommands` — and a second binding here meant one keystroke
        // both captured to the Inbox *and* created into the open screen.
    }
}

extension View {
    /// The pushed detail page, on the platforms that use one.
    ///
    /// macOS presents the editor as a popover anchored to the row itself — see
    /// `todoDetailPopover(for:selection:)`, attached in the list. iOS keeps the
    /// pushed page, which is the right shape for a single-screen device.
    @ViewBuilder
    func todoDetailDestination(selection: Binding<Todo?>) -> some View {
        #if os(macOS)
        self
        #else
        self.navigationDestination(item: selection) { todo in
            TodoDetailView(todo: todo)
        }
        #endif
    }
}

#if DEBUG
#Preview("Root") {
    // The whole shell: four tabs, with Today's summary showing first.
    RootView(windowState: .constant(WindowState()))
        .previewEnvironment()
}
#endif
