import SwiftUI
import SwiftData

/// The app shell: hamburger sidebar, main content, and — on wide layouts — the
/// optional right-hand Inbox/overdue panel.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query private var todos: [Todo]

    /// The app launches on Today, per the spec.
    @State private var selection: ListDestination? = .today
    @State private var selectedTodo: Todo?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// `-startInCalendar` opens straight into the calendar, for UI verification.
    @State private var showsCalendar = ProcessInfo.processInfo.arguments.contains("-startInCalendar")
    @State private var didRunLaunchTasks = false
    @State private var importer = RemindersImporter.shared

    @Environment(\.scenePhase) private var scenePhase

    /// Shortest gap between foreground rescans, so flicking in and out of the
    /// app does not re-query EventKit repeatedly.
    private let rescanDebounce: TimeInterval = 30

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isWideLayout: Bool { horizontalSizeClass == .regular }
    #else
    private var isWideLayout: Bool { true }
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: 200, ideal: Theme.Metrics.sidebarWidth, max: 320
                )
        } detail: {
            NavigationStack {
                HStack(spacing: 0) {
                    mainContent

                    // Right-hand panel: wide layouts only, and only when the
                    // user has it switched on.
                    if isWideLayout && settings.showSidePanel {
                        Divider()
                        SidePanelView(selectedTodo: $selectedTodo)
                            .frame(width: Theme.Metrics.sidePanelWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Theme.Animation.panel, value: settings.showSidePanel)
                .toolbar { toolbarContent }
                .navigationDestination(item: $selectedTodo) { todo in
                    TodoDetailView(todo: todo)
                }
            }
        }
        .task {
            guard !didRunLaunchTasks else { return }
            didRunLaunchTasks = true
            await runLaunchTasks()
        }
        // Returning to the app re-scans, so reminders added elsewhere while it
        // was backgrounded show up without a relaunch.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, didRunLaunchTasks else { return }

            if let last = importer.lastScanDate,
               Date().timeIntervalSince(last) < rescanDebounce {
                return
            }

            Task { await scanReminders() }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if showsCalendar {
            CalendarView(selectedTodo: $selectedTodo)
                .frame(maxWidth: .infinity)
        } else {
            TodoListView(
                destination: selection ?? .today,
                selectedTodo: $selectedTodo
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(Theme.Animation.panel) { showsCalendar.toggle() }
            } label: {
                Label(
                    showsCalendar ? "List View" : "Calendar View",
                    systemImage: showsCalendar ? "list.bullet" : "calendar"
                )
            }
        }

        if isWideLayout {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(Theme.Animation.panel) {
                        settings.showSidePanel.toggle()
                    }
                } label: {
                    Label("Toggle Panel", systemImage: "sidebar.right")
                }
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
        if ProcessInfo.processInfo.arguments.contains("-seedCalendarEvents") {
            await DebugCalendarSeeder.seed()
        }
        if ProcessInfo.processInfo.arguments.contains("-seedReminders") {
            await DebugCalendarSeeder.seedReminders()
        }
        #endif

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
