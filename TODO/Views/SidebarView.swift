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
    @Query private var spaces: [Space]
    @Query private var todos: [Todo]

    /// The sidebar's own pull-down search, which searches everything rather
    /// than one list.
    @State private var searchText = ""

    @State private var isCreatingSpace = false
    @State private var isShowingSettings = false
    @State private var editingSpace: Space?
    /// Set while confirming a space deletion, which takes its contents with it.
    @State private var pendingDeletion: Space?

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
                    Label("New Space", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                // macOS gets the standard Settings scene; on the other
                // platforms this is the way in.
                #if !os(macOS)
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                #endif
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
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
        TodoSearch.matches(todos, query: searchText, scope: .unresolved)
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
                    store: store,
                    allTodos: todos,
                    spaces: spaces
                )
            }
        }

        // Projects with no space, listed before the space sections.
        let loose = TodoQueries.looseProjects(todos)
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
                            if space.openCount > 0 {
                                Text("\(space.openCount)")
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
                    store: store,
                    allTodos: todos,
                    spaces: spaces
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

                ForEach(space.projects) { project in
                    projectLink(project)
                        .padding(.leading, 12)
                }
                .onMove { indices, newOffset in
                    var reordered = space.projects
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
            store: store,
            allTodos: todos,
            spaces: spaces
        )
    }

    /// Inbox is deliberately absent: it is its own tab, and listing it here too
    /// would give one screen two entry points with no way to tell them apart.
    private var fixedDestinations: [ListDestination] {
        [.today, .thisWeek, .anytime, .logbook]
    }

    /// Spell out what a space deletion takes with it, counting the projects and
    /// to-dos separately since they read differently to the user.
    private var deletePrompt: String {
        guard let space = pendingDeletion else { return "" }

        let projects = space.projects.count
        let others = space.todoList.count - projects

        var parts: [String] = []
        if projects > 0 { parts.append("\(projects) project\(projects == 1 ? "" : "s")") }
        if others > 0 { parts.append("\(others) to-do\(others == 1 ? "" : "s")") }

        guard !parts.isEmpty else {
            return "Delete “\(space.name)”? This cannot be undone."
        }
        return "Deleting “\(space.name)” also deletes its \(parts.joined(separator: " and ")). This cannot be undone."
    }

    /// Spaces the active Focus allows, in display order.
    ///
    /// A Focus filter hides whole spaces from the sidebar, so a Focus that
    /// selects only "Work" leaves the personal spaces out of the list entirely
    /// rather than merely dimming them.
    private var orderedSpaces: [Space] {
        spaces.visibleUnderFocus
    }

    /// Whether a Focus is currently hiding at least one space, which the footer
    /// notes so a missing space never looks like data loss.
    private var hiddenSpaceCount: Int {
        spaces.filter(\.isHiddenByFocus).count
    }

    private func badgeCount(for destination: ListDestination) -> Int {
        switch destination {
        case .inbox: TodoQueries.inbox(todos, includeResolved: false).count
        case .today: TodoQueries.today(todos, includeResolved: false).count
        case .thisWeek: TodoQueries.thisWeek(todos, includeResolved: false).count
        case .anytime: TodoQueries.anytime(todos, includeResolved: false).count
        default: 0
        }
    }

    private func color(for destination: ListDestination) -> Color {
        switch destination {
        case .inbox: .blue
        case .today: .yellow
        case .thisWeek: .green
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
