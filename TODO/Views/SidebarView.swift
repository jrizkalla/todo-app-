import SwiftUI
import SwiftData

/// The left menu: fixed lists on top, then projects grouped by space.
///
/// Ordering is user-controlled — spaces and the projects inside them can be
/// dragged, and the new order is written back to `sortIndex`.
struct SidebarView: View {
    @Binding var selection: ListDestination?
    /// Opening a search result means opening its detail page, which is the
    /// detail column's business — hence the binding up to `RootView`.
    @Binding var selectedTodo: Todo?

    @Environment(\.modelContext) private var context
    /// Opens a second window onto a space or project. Every window carries its
    /// own `WindowState`, so the new one is independent of this one — and a
    /// to-do can be dragged between the two.
    @Environment(\.openWindow) private var openWindow
    /// The spaces to draw, filtered and ordered by SQLite.
    ///
    /// The Focus rule and the sort are both predicates now, and the query
    /// prefetches each space's to-dos: this view draws a row per space and the
    /// project list under it, so the relationship is read for every one — the
    /// case `prefetchTodos` exists for.
    @Query(TodoQueries.visibleSpacesDescriptor())
    private var orderedSpaces: [Space]

    /// The sidebar's own pull-down search, which searches everything rather
    /// than one list.
    @State private var searchText = ""

    @State private var isCreatingSpace = false
    @State private var isShowingSettings = false
    @State private var editingSpace: Space?
    /// Set while confirming a space deletion, which takes its contents with it.
    @State private var pendingDeletion: Space?
    /// Same, for a project — which takes its subtasks with it.
    @State private var pendingProjectDeletion: Todo?

    /// The project whose editor this column is showing, on macOS.
    ///
    /// Deliberately *not* `selectedTodo`. That binding is shared with the list,
    /// which anchors a popover of its own to the same to-do whenever the list
    /// it is showing is that project — and two popovers bound to one value
    /// present neither, so Edit Project… did nothing precisely when the user
    /// was already inside the project they right-clicked. Sidebar-local state
    /// gives this column a presentation the list cannot collide with.
    ///
    /// iOS is unaffected and keeps using the shared binding: there the editor
    /// is a pushed page, and one stack can only show one of them anyway.
    @State private var editingProject: Todo?

    /// False on a phone, where the system refuses a second scene — the command
    /// is withdrawn rather than offered and then ignored.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        // One `List` throughout, with its *contents* swapped rather than the
        // list itself. Replacing the whole container while the search field is
        // presented tears down the `selection` binding with it, which leaves
        // the destination rows visible but unresponsive once the field is
        // dismissed.
        List(selection: $selection) {
            if isSearching {
                searchResultRows
            } else {
                navigationRows
            }
        }
        .overlay {
            if isSearching && searchResults.isEmpty {
                SearchEmptyState(query: searchText, scopeDescription: "in your lists")
                    .background(.background)
            }
        }
        .navigationTitle("Lists")
        // The editor has to be presentable from *this* column. `RootView`
        // attaches its `navigationDestination` to the detail column's stack,
        // which is a different stack from the one the sidebar is in — so a
        // to-do named from here (Edit Project…, or a search result) set the
        // binding and then nothing opened. On macOS this is a no-op: there the
        // editor is a popover anchored to the project row itself.
        .todoDetailDestination(selection: $selectedTodo)
        .toolbar {
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
        }
        // Same gesture as inside a list, so the field is where the user
        // reaches for it no matter which column they are in — on iOS. macOS
        // has one toolbar for both columns and only room for one search field,
        // which the list pane takes.
        .columnScopedSearchable(text: $searchText, prompt: "Search All Lists")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    isCreatingSpace = true
                } label: {
                    HStack {
                        Spacer()
                        Label("New Space", systemImage: "plus.circle")
                            .font(.callout)
                        Spacer()
                    }
                    .frame(height: 30)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
//            .background(.bar)
        }
        #if !os(macOS)
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
            }
        }
        #endif
        .sheet(item: $editingSpace) { space in
            NavigationStack {
                SpaceEditorView(space: space)
            }
        }
        .sheet(isPresented: $isCreatingSpace) {
            NavigationStack {
                SpaceEditorView(space: nil)
            }
        }
    }

    /// Whether the sidebar is showing results instead of its lists.
    private var isSearching: Bool {
        TodoSearch.isActive(searchText)
    }

    /// Unresolved work from every list, matching what has been typed.
    ///
    /// Deliberately a flat list of to-dos rather than a filtered tree of spaces
    /// and projects: the sidebar's field exists to jump straight to an item the
    /// user cannot remember the location of, so grouping it back under the
    /// containers they could not recall would defeat the point.
    private var searchResults: [Todo] {
        TodoSearch.matches(query: searchText, scope: .unresolved, context: context)
    }

    /// Selecting a result opens its detail page.
    private var searchResultRows: some View {
        ForEach(searchResults) { todo in
            Button {
                selectedTodo = todo
            } label: {
                SearchResultRow(todo: todo)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var navigationRows: some View {
        Section {
            ForEach(fixedDestinations, id: \.self) { destination in
                NavigationLink(value: destination) {
                    Label {
                        HStack {
                            Text(destination.title)
                            Spacer()
                            let count = badgeCount(for: destination)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: destination.symbolName)
                            .foregroundStyle(color(for: destination))
                    }
                }
                // Dropping a to-do here files it as that list implies — Today
                // dates it for today, Inbox strips its home and date. The
                // Logbook refuses, since completing work by dropping it would
                // be too easy to do by accident.
                .todoDropTarget(
                    destination,
                    store: store
                )
                .contextMenu {
                    openInNewWindowButton(destination)
                }
            }
        }

        // Projects with no space, listed before the space sections.
        let loose = TodoQueries.looseProjects(in: context)
        if !loose.isEmpty {
            Section("Projects") {
                ForEach(loose) { project in
                    projectLink(project)
                }
                .onMove { indices, newOffset in
                    var reordered = loose
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    store.reorder(reordered)
                }
            }
        }

        ForEach(orderedSpaces) { space in
            Section {
                NavigationLink(value: ListDestination.space(space.uuid)) {
                    Label {
                        HStack {
                            Text(space.name)
                            Spacer()
                            let openCount = TodoQueries.openCount(
                                inSpace: space.uuid, in: context
                            )
                            if openCount > 0 {
                                Text("\(openCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: space.symbolName)
                            .foregroundStyle(Color(hex: space.colorHex))
                    }
                }
                .todoDropTarget(
                    .space(space.uuid),
                    store: store
                )
                // Menu and confirmation both hang off the space's own row,
                // so the dialog is anchored beside the space it is about.
                // Attached to the Section instead, it points at the whole
                // section — including the projects underneath.
                .contextMenu {
                    Button {
                        editingSpace = space
                    } label: {
                        Label("Edit Space…", systemImage: "paintpalette")
                    }

                    openInNewWindowButton(.space(space.uuid))

                    Button(role: .destructive) {
                        pendingDeletion = space
                    } label: {
                        Label("Delete Space", systemImage: "trash")
                    }
                }
                .confirmationDialog(
                    deletePrompt,
                    isPresented: .init(
                        get: { pendingDeletion?.uuid == space.uuid },
                        set: { if !$0 { pendingDeletion = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Space", role: .destructive) {
                        if case .space(let id) = selection, id == space.uuid {
                            // The list being shown is about to disappear.
                            selection = .today
                        }
                        store.delete(space)
                        pendingDeletion = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDeletion = nil }
                }

                let projects = TodoQueries.projects(inSpace: space.uuid, in: context)
                ForEach(projects) { project in
                    projectLink(project)
                        .padding(.leading, 12)
                }
                .onMove { indices, newOffset in
                    var reordered = projects
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    store.reorder(reordered)
                }
            }
        }

        // A space vanishing because of a Focus should read as a filter, not
        // as something having gone missing.
        if hiddenSpaceCount > 0 {
            Section {
                Label(
                    "\(hiddenSpaceCount) space\(hiddenSpaceCount == 1 ? "" : "s") hidden by Focus",
                    systemImage: "moon.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func projectLink(_ project: Todo) -> some View {
        NavigationLink(value: ListDestination.project(project.uuid)) {
            Label {
                HStack {
                    InlineMarkdownText(markdown: project.title.isEmpty ? "Untitled Project" : project.title)
                    Spacer()
                    let remaining = project.subtaskList.filter { !$0.state.isResolved }.count
                    if remaining > 0 {
                        Text("\(remaining)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(project.resolvedColorHex.map { Color(hex: $0) } ?? .secondary)
            }
        }
        // Dropping onto a project adopts the to-do as one of its subtasks.
        .todoDropTarget(
            .project(project.uuid),
            store: store
        )
        // A project is a to-do, so its own detail page is already the editor
        // for everything on it — title, scheduled date, deadline, place. The
        // sidebar simply had no way to reach it: the row navigated to the
        // project's *list*, and nothing anywhere opened the project itself.
        .contextMenu {
            Button {
                // macOS opens this column's own popover; iOS pushes the shared
                // detail page — see `editingProject`.
                #if os(macOS)
                editingProject = project
                #else
                selectedTodo = project
                #endif
            } label: {
                Label("Edit Project…", systemImage: "slider.horizontal.3")
            }
            
            Button {
                store.duplicate(project)
            } label: {
                Label("Duplicate Project", systemImage: "plus.square")
            }

            openInNewWindowButton(.project(project.uuid))

            Button(role: .destructive) {
                pendingProjectDeletion = project
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
        .confirmationDialog(
            deleteProjectPrompt,
            isPresented: .init(
                get: { pendingProjectDeletion?.uuid == project.uuid },
                set: { if !$0 { pendingProjectDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                // The list being shown is about to disappear.
                if case .project(let id) = selection, id == project.uuid {
                    selection = .today
                }
                store.delete(project)
                pendingProjectDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingProjectDeletion = nil }
        }
        // macOS presents the editor as a popover anchored to the row it is
        // about; on iOS this is a no-op and the detail page is pushed instead.
        .todoDetailPopover(for: project, selection: $editingProject)
    }

    /// Opens `destination` in a window of its own.
    ///
    /// Windows are keyed on `WindowState`, so this both creates the window and
    /// says what it should be showing. Each gets a fresh id, which is what lets
    /// two windows sit on the same list rather than the second request merely
    /// bringing the first forward — see `WindowState.id`.
    ///
    /// macOS and iPadOS only: a phone shows one scene at a time, and the
    /// command would open a window the user cannot get back from.
    @ViewBuilder
    private func openInNewWindowButton(_ destination: ListDestination) -> some View {
        #if os(macOS) || os(iOS)
        if supportsMultipleWindows {
            Button {
                openWindow(value: WindowState.showing(destination))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.on.rectangle")
            }
        }
        #endif
    }

    /// The Inbox leads, but only where it has no tab of its own.
    ///
    /// One screen with two entry points gives the user no way to tell which one
    /// they are on, so exactly one of the tab and this row exists. On a phone —
    /// the only place the app cannot open a second window — the tab is the one
    /// that survives, because a sidebar row there is two navigation steps from
    /// anywhere. Everywhere else this row is, and the Inbox can be pulled into
    /// a window of its own like any other list. See `RootView.showsInboxTab`.
    private var fixedDestinations: [ListDestination] {
        let dated: [ListDestination] = [
            .today, .tomorrow, .thisWeek, .nextWeek, .anytime, .logbook,
        ]
        let placement = InboxPlacement.forLayout(
            supportsMultipleWindows: supportsMultipleWindows
        )
        return placement.showsSidebarRow ? [.inbox] + dated : dated
    }

    /// Spell out what a space deletion takes with it, counting the projects and
    /// to-dos separately since they read differently to the user.
    private var deletePrompt: String {
        guard let space = pendingDeletion else { return "" }

        let (projects, others) = TodoQueries.spaceContentCounts(
            spaceID: space.uuid, in: context
        )

        var parts: [String] = []
        if projects > 0 { parts.append("\(projects) project\(projects == 1 ? "" : "s")") }
        if others > 0 { parts.append("\(others) to-do\(others == 1 ? "" : "s")") }

        guard !parts.isEmpty else {
            return "Delete “\(space.name)”? This cannot be undone."
        }
        return "Deleting “\(space.name)” also deletes its \(parts.joined(separator: " and ")). This cannot be undone."
    }

    /// Same for a project, which takes its subtasks with it.
    private var deleteProjectPrompt: String {
        guard let project = pendingProjectDeletion else { return "" }
        let name = project.title.isEmpty ? "Untitled Project" : project.title
        let count = project.subtaskList.count

        guard count > 0 else {
            return "Delete “\(name)”? This cannot be undone."
        }
        return "Deleting “\(name)” also deletes its \(count) to-do\(count == 1 ? "" : "s"). This cannot be undone."
    }

    /// Whether a Focus is currently hiding at least one space, which the footer
    /// notes so a missing space never looks like data loss.
    ///
    /// Counted in SQLite: `orderedSpaces` no longer holds the hidden ones to
    /// count, and the footer only ever wanted the number.
    private var hiddenSpaceCount: Int {
        TodoQueries.hiddenSpaceCount(in: context)
    }

    /// A destination's badge number, counted in SQLite.
    ///
    /// `fetchCount` rather than fetching and measuring: the badge only ever
    /// needed the number, and building the whole array to read `.count` was
    /// what made five badges cost five passes over the store.
    private func badgeCount(for destination: ListDestination) -> Int {
        TodoQueries.count(for: destination, in: context)
    }

    private func color(for destination: ListDestination) -> Color {
        switch destination {
        case .inbox: .blue
        case .today: .yellow
        case .tomorrow: .orange
        case .thisWeek: .green
        case .nextWeek: .mint
        case .anytime: .teal
        case .logbook: .secondary
        default: .accentColor
        }
    }
}

#if DEBUG
private struct SidebarPreviewHost: View {
    @State private var selection: ListDestination? = .today
    @State private var selectedTodo: Todo?

    var body: some View {
        NavigationStack {
            SidebarView(selection: $selection, selectedTodo: $selectedTodo)
        }
    }
}

#Preview("Sidebar") {
    // Fixed lists with badge counts, then spaces with their projects.
    SidebarPreviewHost()
        .previewEnvironment()
}

#Preview("No spaces") {
    SidebarPreviewHost()
        .modelContainer(for: AppSchema.models, inMemory: true)
        .environment(AppSettings.shared)
}
#endif
