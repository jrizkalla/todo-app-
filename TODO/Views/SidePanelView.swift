import SwiftUI
import SwiftData

/// Right-hand panel on wide layouts showing unscheduled work.
///
/// The spec asks for this on macOS and iPadOS only; `RootView` gates it on the
/// horizontal size class so it never appears on a phone. It sits beside the
/// whole tab view rather than inside any one tab, so it stays reachable from
/// Today, Lists, and Calendar alike.
///
/// What it holds depends on `scope`. By default that is the Inbox — unfiled
/// work, under anything overdue. Open a space or project *as a calendar* and
/// the panel becomes that container's undated remainder instead, so the grid
/// and the panel together show the whole list: what has a slot, and what is
/// still waiting for one. Which is also what makes the pair usable — an
/// undated item is one drag from the day it belongs on.
struct SidePanelView: View {
    @Binding var selectedTodo: Todo?

    /// What to show. Defaults to the Inbox so the panel stands alone in
    /// previews and wherever nothing has claimed it.
    var scope: SidePanelScope = .inbox

    /// Collapses the panel. Supplied by whoever owns the visibility state —
    /// the panel draws the control but does not decide what hiding means.
    var onHide: (() -> Void)?


    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var todos: [Todo]
    @Query private var spaces: [Space]

    /// Titles are editable here too, so the panel owns its own focus.
    @FocusState private var focusedTodoID: UUID?

    /// Which row is expanded for editing.
    ///
    /// The panel's own state, not `selectedTodo`: that one opens the editor,
    /// and the first tap on a row is only meant to expand it in place. The
    /// panel has no keyboard cursor to hang this on the way the main list
    /// does, so it keeps the id itself.
    @State private var expandedTodoID: UUID?

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        // Built to read as the left sidebar's mirror image: the same `.sidebar`
        // list style, the same section headers, and the same footer bar holding
        // the panel's one control. The panel used to be a `.plain` list on the
        // bare window background, which left it looking like loose text pushed
        // against the right edge rather than a rail of its own.
        List {
            // Overdue rides above whatever the panel is scoped to. Late work is
            // late whichever list is open, and a scoped calendar is exactly
            // where it matters most: the item needs a new slot, and the grid
            // beside the panel is where one gets picked.
            let overdue = self.overdue
            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { todo in
                        row(todo)
                    }
                } header: {
                    Label("Overdue", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.overdue)
                }
            }

            Section {
                let items = contents
                if items.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { todo in
                        row(todo)
                    }
                }
            } header: {
                Label(sectionTitle, systemImage: sectionSymbol)
            }
        }
        .listStyle(.sidebar)
        // The panel is one surface changing what it holds, not two surfaces
        // swapping places, so the rows cross-fade in place rather than the
        // whole card sliding.
        .animation(Theme.Animation.panel, value: scope)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // The hide control rides at the bottom of the card, over the same glass
        // rather than on a bar of its own. A `.bar` background here would draw
        // an opaque strip across the card's rounded bottom corners and undo the
        // floating effect at exactly the point it is most visible.
        .safeAreaInset(edge: .bottom) {
            if let onHide {
                HStack {
                    Spacer()

                    Button(action: onHide) {
                        Image(systemName: "sidebar.right")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hide Side Panel")
                    .help("Hide the side panel")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        // The panel is a floating card, not a wall: the same liquid glass,
        // corner radius, and drop shadow the summary cards use. Sitting flush
        // to the window edges as an opaque slab is what made it read as a flat
        // panel bolted onto the side rather than as a surface of its own
        // hovering above the content.
        .glassCard(cornerRadius: Theme.Metrics.panelCornerRadius)
        .padding(.vertical, Theme.Metrics.panelInset)
        .padding(.trailing, Theme.Metrics.panelInset)
        .frame(
            minWidth: 240 + Theme.Metrics.panelInset,
            idealWidth: Theme.Metrics.sidePanelWidth + Theme.Metrics.panelInset
        )
    }

    // MARK: Scope

    /// The rows under the main header.
    private var contents: [Todo] {
        switch scope {
        case .inbox:
            TodoQueries.inbox(todos, includeResolved: settings.showResolved)
        case .list(let destination):
            // Overdue items are drawn in their own section above, so they are
            // held back here rather than appearing twice in one panel.
            TodoQueries.unscheduled(
                todos,
                for: destination,
                includeResolved: settings.showResolved
            )
            .filter { !$0.isOverdue }
        }
    }

    /// Late work, narrowed to the scope so a container's calendar only ever
    /// answers for its own overruns.
    private var overdue: [Todo] {
        switch scope {
        case .inbox:
            TodoQueries.overdue(todos)
        case .list(let destination):
            TodoQueries.overdue(TodoQueries.calendarScope(todos, for: destination))
        }
    }

    private var sectionTitle: String {
        switch scope {
        case .inbox: "Inbox"
        case .list(let destination): scopeName(destination)
        }
    }

    private var sectionSymbol: String {
        switch scope {
        case .inbox: "tray"
        // Not the destination's own icon: the section is the *unscheduled* part
        // of that list, and reusing the folder or list glyph would read as the
        // whole thing.
        case .list: "calendar.badge.clock"
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .inbox: "Inbox is empty"
        case .list: "Everything here is scheduled"
        }
    }

    /// The user-facing name of a scoped destination, resolved the same way the
    /// list's own title is.
    private func scopeName(_ destination: ListDestination) -> String {
        switch destination {
        case .space(let id):
            spaces.first { $0.uuid == id }?.name ?? "Space"
        case .project(let id):
            todos.first { $0.uuid == id }?.title ?? "Project"
        default:
            destination.title
        }
    }

    /// Whether rows name the space they came from.
    ///
    /// Worth it in the Inbox, where the rows are a mixed bag from everywhere.
    /// Inside a space's own scope every row carries the same badge, which says
    /// nothing and takes width the title needs — a project keeps it, though,
    /// since a project's work can sit in a space the header does not name.
    private var showsSpaceBadge: Bool {
        switch scope {
        case .inbox: true
        case .list(let destination):
            if case .space = destination { false } else { true }
        }
    }

    // MARK: Rows

    private func row(_ todo: Todo) -> some View {
        TodoRow(
            todo: todo,
            showsSpace: showsSpaceBadge,
            isSelected: expandedTodoID == todo.uuid,
            onToggle: { _ in
                // Cascade silently here: the panel is a glanceable surface and
                // a modal prompt would be disruptive. The full prompt still
                // appears in the main list.
                if case .needsSubtaskConfirmation = store.setState(todo, to: todo.toggledState) {
                    store.setStateCascading(todo, to: todo.toggledState)
                }
            },
            onSelectState: { newState in
                if case .needsSubtaskConfirmation = store.setState(todo, to: newState) {
                    store.setStateCascading(todo, to: newState)
                }
            },
            onTitleChange: { _ in store.save() },
            onNotesChange: { _ in store.save() },
            menu: {
                AnyView(
                    Button {
                        focusedTodoID = nil
                        selectedTodo = todo
                    } label: {
                        Label("Show Details", systemImage: "info.circle")
                    }
                )
            },
            onSubmitTitle: {},
            onShowDetail: { todo in
                focusedTodoID = nil
                selectedTodo = todo
            },
            focusedTodoID: $focusedTodoID
        )
        // Enough inset to line the checkboxes up with the sidebar's icons.
        // Zeroed insets pushed the rows flush to the panel's edges, which is
        // most of what made it read as unstyled text beside a styled rail.
        .listRowInsets(EdgeInsets(
            top: 2,
            leading: Theme.Metrics.listContentMargin,
            bottom: 2,
            trailing: Theme.Metrics.listContentMargin
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // Expanding is the panel's call, not the row's — see `TodoRow`.
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandedTodoID != todo.uuid else { return }
            withAnimation(Theme.Animation.rowExpand) { expandedTodoID = todo.uuid }
        }
        // The panel sits beside every tab, so dragging out of it is the
        // shortest path from unfiled work to a list or a calendar slot.
        // Suppressed while the title is being typed into, as in the main list.
        .todoDraggable(todo, isEnabled: focusedTodoID != todo.uuid)
        // The panel selects to-dos too, so its rows anchor the editor popover
        // the same way the main list's do.
        .todoDetailPopover(for: todo, selection: $selectedTodo)
    }
}

#if DEBUG
private struct SidePanelPreviewHost: View {
    var scope: SidePanelScope = .inbox
    @State private var selected: Todo?

    var body: some View {
        SidePanelView(selectedTodo: $selected, scope: scope)
    }
}

#Preview("Side panel") {
    // Overdue work on top, then the Inbox.
    SidePanelPreviewHost()
        .previewEnvironment()
}

#Preview("Side panel — scoped to a space") {
    // What the panel becomes beside a space's calendar: that space's undated
    // work, with the grid holding everything that does have a day.
    SidePanelPreviewHost(scope: .list(.space(PreviewData.space.uuid)))
        .previewEnvironment()
}
#endif
