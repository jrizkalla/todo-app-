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
                    Button(role: .destructive) {
                        store.delete(space)
                    } label: {
                        Label("Delete Space", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .safeAreaInset(edge: .bottom) {
            Button {
                isCreatingSpace = true
            } label: {
                Label("New Space", systemImage: "plus.circle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(.bar)
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
                    .foregroundStyle(project.space.map { Color(hex: $0.colorHex) } ?? .secondary)
            }
        }
    }

    private var fixedDestinations: [ListDestination] {
        [.inbox, .today, .thisWeek, .anytime, .logbook]
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
