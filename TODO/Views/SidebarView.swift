import SwiftUI
import SwiftData

/// The left menu: fixed lists on top, then projects grouped by space.
///
/// Ordering is user-controlled — spaces and the projects inside them can be
/// dragged, and the new order is written back to `sortIndex`.
struct SidebarView: View {
    @Binding var selection: ListDestination?

    @Environment(\.modelContext) private var context
    @Query private var spaces: [Space]
    @Query private var todos: [Todo]

    @State private var isCreatingSpace = false
    @State private var newSpaceName = ""
    @State private var isShowingSettings = false
    @State private var editingSpace: Space?
    /// Set while confirming a space deletion, which takes its contents with it.
    @State private var pendingDeletion: Space?

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        List(selection: $selection) {
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
            }
        }
        .navigationTitle("Lists")
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
        // Deleting a space cascades to everything filed in it, which the
        // sidebar row does not make obvious.
        .confirmationDialog(
            deletePrompt,
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let space = pendingDeletion {
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
        }
        .alert("New Space", isPresented: $isCreatingSpace) {
            TextField("Name", text: $newSpaceName)
            Button("Cancel", role: .cancel) { newSpaceName = "" }
            Button("Create") {
                let name = newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let index = orderedSpaces.count % Theme.Palette.spaceColors.count
                    store.createSpace(name: name, colorHex: Theme.Palette.spaceColors[index])
                }
                newSpaceName = ""
            }
        } message: {
            Text("Spaces group related projects and to-dos.")
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
    }

    private var fixedDestinations: [ListDestination] {
        [.inbox, .today, .thisWeek, .anytime, .logbook]
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

    private var orderedSpaces: [Space] {
        spaces.sorted { $0.sortIndex < $1.sortIndex }
    }

    private func badgeCount(for destination: ListDestination) -> Int {
        switch destination {
        case .inbox: TodoQueries.inbox(todos).count
        case .today: TodoQueries.today(todos).count
        case .thisWeek: TodoQueries.thisWeek(todos).count
        case .anytime: TodoQueries.anytime(todos).count
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

    var body: some View {
        NavigationStack {
            SidebarView(selection: $selection)
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
