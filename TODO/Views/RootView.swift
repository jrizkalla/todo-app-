import SwiftUI
import SwiftData

/// The app's top-level tabs.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
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
    @Query private var todos: [Todo]

    /// The app launches on Today, per the spec.
    @State private var tab: AppTab = .today

    /// Per-tab navigation state. Kept here so a tap on a summary card can move
    /// the user to another tab *and* set what that tab is showing.
    @State private var listSelection: ListDestination? = .today
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

    private func createCount(for tab: AppTab) -> Binding<Int> {
        Binding(
            get: { createRequests[tab] ?? 0 },
            set: { createRequests[tab] = $0 }
        )
    }

    @State private var didRunLaunchTasks = false
    @State private var importer = RemindersImporter.shared

    /// What the side panel is showing. Normally the Inbox; a scoped calendar
    /// pushed anywhere in the app points it at its own list instead.
    @State private var panelScope = SidePanelScopeModel.shared

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
        // Wide layouts keep the Inbox panel beside *every* tab, so it is one
        // persistent surface rather than something only the Lists tab has.
        // Phones fall through to the bare tab view untouched.
        Group {
            if isWideLayout {
                // The panel is an *overlay*, not a sibling in a stack, so it
                // draws above the tab content rather than beside it; `tabs`
                // reserves the width with a matching trailing inset, so no
                // content ends up hidden behind the card.
                //
                // It deliberately stops below the toolbar. On macOS the search
                // field is a window toolbar item spanning the whole window — it
                // is not confined to the tab column and pays no attention to
                // content safe areas — so anything drawn up into that strip
                // collides with it. Running the card to the window's very top
                // is what put the field on top of it.
                tabs
                    .safeAreaPadding(.trailing, settings.showSidePanel ? panelColumn : 0)
                    .overlay(alignment: .trailing) {
                        if settings.showSidePanel {
                            SidePanelView(
                                selectedTodo: $selectedTodo,
                                scope: effectivePanelScope,
                                onHide: { settings.showSidePanel = false }
                            )
                            .frame(width: panelColumn)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.Animation.panel, value: settings.showSidePanel)
                    // Bringing the panel back once hidden: the toggle in
                    // Settings still works, but a control on the shell itself
                    // means the user does not have to leave the screen to undo
                    // a collapse.
                    .overlay(alignment: .topTrailing) {
                        if !settings.showSidePanel {
                            showPanelButton
                        }
                    }
            } else {
                tabs
            }
        }
        // Showing the panel retires the Inbox tab, so anyone standing on it
        // when that happens has to be moved somewhere that still exists —
        // otherwise the selection points at a tab the bar no longer draws and
        // the content area comes up blank.
        .onChange(of: showsInboxTab) { _, showsTab in
            if !showsTab && tab == .inbox { tab = .today }
        }
    }

    /// Reveals the panel again after it has been collapsed.
    private var showPanelButton: some View {
        Button {
            settings.showSidePanel = true
        } label: {
            Image(systemName: "sidebar.right")
                .font(.body.weight(.medium))
                .padding(8)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, 12)
        .padding(.top, 8)
        .accessibilityLabel("Show Inbox Panel")
        .help("Show the Inbox panel")
        .transition(.opacity)
    }

    /// Whether the Inbox deserves a tab of its own.
    private var showsInboxTab: Bool { !isWideLayout }

    /// What the panel actually shows, once the open tab is taken into account.
    ///
    /// A scoped calendar only holds the panel while the user is *looking* at
    /// it. The Lists tab keeps its pushed screens mounted across a tab switch,
    /// so the claim outlives the visit — without this, walking from a space's
    /// calendar over to Today left that space's undated work sitting beside the
    /// summary, where it means nothing and the Inbox is what belongs. Coming
    /// back to Lists finds the calendar still pushed and the scope with it.
    private var effectivePanelScope: SidePanelScope {
        tab == .lists ? panelScope.scope : .inbox
    }

    /// Width the panel occupies, card plus the inset it carries itself.
    private var panelColumn: CGFloat {
        Theme.Metrics.sidePanelWidth + Theme.Metrics.panelInset
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            if showsInboxTab {
                Tab(AppTab.inbox.title, systemImage: AppTab.inbox.symbol, value: AppTab.inbox) {
                    NavigationStack {
                        TodoListView(
                            destination: .inbox,
                            selectedTodo: $selectedTodo,
                            createRequest: createCount(for: .inbox)
                        )
                        .todoDetailDestination(selection: $selectedTodo)
                    }
                }
            }

            Tab(AppTab.today.title, systemImage: AppTab.today.symbol, value: AppTab.today) {
                NavigationStack {
                    AISummaryView(
                        onOpenSchedule: {
                            calendarAnchor = Date()
                            calendarScale = .day
                            tab = .calendar
                        },
                        onOpenAnyTime: {
                            listSelection = .today
                            tab = .lists
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
            if tab != .today {
                CreateButton {
                    createRequests[tab, default: 0] += 1
                }
                .padding(.bottom, Theme.Metrics.createButtonTabBarClearance)
                // Scales out of the corner it sits in rather than blinking, so
                // arriving on Today reads as the button leaving.
                .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.panel, value: tab)
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

    /// Lists: the sidebar of spaces and projects, with the selected list beside
    /// or pushed from it.
    ///
    /// Inbox is deliberately absent from the sidebar here — it has its own tab,
    /// and listing it twice would leave two ways to reach one screen with no
    /// way to tell which one the user is on.
    private var listsTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $listSelection, selectedTodo: $selectedTodo)
                .navigationSplitViewColumnWidth(
                    min: 200, ideal: Theme.Metrics.sidebarWidth, max: 320
                )
        } detail: {
            NavigationStack {
                TodoListView(
                    destination: listSelection ?? .today,
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
            tab = .calendar
        }
        // Likewise for Lists, which is the tab the side panel sits beside the
        // real sidebar on — the arrangement worth looking at when the panel's
        // chrome changes.
        if ProcessInfo.processInfo.arguments.contains("-startInLists") {
            tab = .lists
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
                .background {
                    Circle().fill(Color.accentColor)
                        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
                }
        }
        // The same press response the summary cards use — one feel for every
        // custom control in the app.
        .buttonStyle(PressableCardStyle(pressedScale: 0.92))
        .padding(.trailing, Theme.Metrics.createButtonInset)
        .padding(.bottom, Theme.Metrics.createButtonInset)
        .accessibilityLabel("New To-Do")
        .keyboardShortcut("n", modifiers: .command)
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
    RootView()
        .previewEnvironment()
}
#endif
