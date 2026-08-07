import SwiftUI
import SwiftData

/// The main list pane for a sidebar destination.
struct TodoListView: View {
    let destination: ListDestination

    @Environment(\.modelContext) private var context
    @Query private var todos: [Todo]
    @Query private var spaces: [Space]

    @Binding var selectedTodo: Todo?

    /// Set while waiting on the user's answer to the cascade prompt.
    @State private var pendingCascade: PendingCascade?

    private var store: TodoStore { TodoStore(context: context) }

    /// A blocked state change awaiting confirmation, per the spec's rule that
    /// the app should ask before resolving a parent's subtasks.
    private struct PendingCascade: Identifiable {
        let id = UUID()
        let todo: Todo
        let target: CompletionState
        let blockedCount: Int
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            listContent
            createButton
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .confirmationDialog(
            cascadePrompt,
            isPresented: .init(
                get: { pendingCascade != nil },
                set: { if !$0 { pendingCascade = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingCascade {
                Button(pending.target == .completed ? "Complete All" : "Cancel All") {
                    store.setStateCascading(pending.todo, to: pending.target)
                    pendingCascade = nil
                }
                Button("Keep Subtasks", role: .cancel) {
                    pendingCascade = nil
                }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if visibleTodos.isEmpty {
            emptyState
        } else {
            List {
                ForEach(visibleTodos) { todo in
                    VStack(spacing: 0) {
                        TodoRow(
                            todo: todo,
                            showsSpace: showsSpaceBadge,
                            isSelected: selectedTodo?.uuid == todo.uuid,
                            onToggle: { handleToggle(todo) },
                            onSelectState: { handleSetState(todo, to: $0) }
                        )
                        .onTapGesture { selectedTodo = todo }

                        // Subtasks nest under their parent rather than
                        // appearing as separate top-level rows.
                        ForEach(todo.orderedSubtasks) { subtask in
                            TodoRow(
                                todo: subtask,
                                isSelected: selectedTodo?.uuid == subtask.uuid,
                                onToggle: { handleToggle(subtask) },
                                onSelectState: { handleSetState(subtask, to: $0) }
                            )
                            .padding(.leading, 28)
                            .onTapGesture { selectedTodo = subtask }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(todo)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        rowMenu(for: todo)
                    }
                }
                .onMove { indices, newOffset in
                    var reordered = visibleTodos
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    store.reorder(reordered)
                }

                // Breathing room so the floating button never covers a row.
                Color.clear.frame(height: 72).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .animation(Theme.Animation.listChange, value: visibleTodos.map(\.uuid))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: destination.symbolName)
        } description: {
            Text(emptyMessage)
        }
    }

    /// The spec asks for a floating create button on the left.
    private var createButton: some View {
        Button {
            let created = store.createTodo(
                space: defaultSpace,
                parent: defaultParent,
                assignedDate: defaultAssignedDate
            )
            selectedTodo = created
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background {
                    Circle().fill(Color.accentColor)
                        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
                }
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.bottom, 22)
        .accessibilityLabel("New To-Do")
        .keyboardShortcut("n", modifiers: .command)
    }

    @ViewBuilder
    private func rowMenu(for todo: Todo) -> some View {
        Button {
            store.addSubtask(to: todo)
        } label: {
            Label("Add Subtask", systemImage: "plus.square.on.square")
        }

        Button {
            store.setIsProject(todo, !todo.isProject)
        } label: {
            Label(
                todo.isProject ? "Demote to To-Do" : "Make Project",
                systemImage: todo.isProject ? "arrow.down.square" : "arrow.up.square"
            )
        }

        Menu("Move to Space") {
            Button("None") { store.move(todo, toSpace: nil) }
            ForEach(spaces.sorted { $0.sortIndex < $1.sortIndex }) { space in
                Button(space.name) { store.move(todo, toSpace: space) }
            }
        }

        Divider()

        Button(role: .destructive) {
            store.delete(todo)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: State changes

    private func handleToggle(_ todo: Todo) {
        handleSetState(todo, to: todo.toggledState)
    }

    /// Route a state change through the store, raising the cascade prompt when
    /// unresolved subtasks block it.
    private func handleSetState(_ todo: Todo, to newState: CompletionState) {
        switch store.setState(todo, to: newState) {
        case .applied:
            break
        case .needsSubtaskConfirmation(let count):
            pendingCascade = PendingCascade(todo: todo, target: newState, blockedCount: count)
        }
    }

    private var cascadePrompt: String {
        guard let pending = pendingCascade else { return "" }
        let verb = pending.target == .completed ? "complete" : "cancel"
        let noun = pending.blockedCount == 1 ? "subtask" : "subtasks"
        return "This to-do has \(pending.blockedCount) unfinished \(noun). Also mark them \(verb == "complete" ? "completed" : "cancelled")?"
    }

    // MARK: Content

    private var visibleTodos: [Todo] {
        switch destination {
        case .inbox: TodoQueries.inbox(todos)
        case .today: TodoQueries.today(todos, calendar: AppSettings.shared.calendar)
        case .thisWeek: TodoQueries.thisWeek(todos, calendar: AppSettings.shared.calendar)
        case .anytime: TodoQueries.anytime(todos)
        case .logbook: TodoQueries.logbook(todos)
        case .space(let id): TodoQueries.inSpace(todos, spaceID: id)
        case .project(let id): TodoQueries.inProject(todos, projectID: id)
        }
    }

    private var title: String {
        switch destination {
        case .space(let id):
            spaces.first { $0.uuid == id }?.name ?? "Space"
        case .project(let id):
            todos.first { $0.uuid == id }?.title ?? "Project"
        default:
            destination.title
        }
    }

    /// Show the space badge on cross-cutting lists where items come from
    /// several places.
    private var showsSpaceBadge: Bool {
        switch destination {
        case .today, .thisWeek, .anytime, .logbook: true
        default: false
        }
    }

    /// A todo created inside a space or project belongs there.
    private var defaultSpace: Space? {
        if case .space(let id) = destination {
            return spaces.first { $0.uuid == id }
        }
        if case .project(let id) = destination {
            return todos.first { $0.uuid == id }?.space
        }
        return nil
    }

    private var defaultParent: Todo? {
        if case .project(let id) = destination {
            return todos.first { $0.uuid == id }
        }
        return nil
    }

    /// Creating from Today schedules for today, which is what the list implies.
    private var defaultAssignedDate: Date? {
        switch destination {
        case .today: Calendar.current.startOfDay(for: Date())
        default: nil
        }
    }

    private var emptyTitle: String {
        switch destination {
        case .inbox: "Inbox Zero"
        case .today: "Nothing Today"
        case .thisWeek: "Nothing This Week"
        case .logbook: "No History Yet"
        default: "Nothing Here"
        }
    }

    private var emptyMessage: String {
        switch destination {
        case .inbox: "New to-dos land here until you give them a date or a home."
        case .today: "Tap + to add something for today."
        case .thisWeek: "Nothing is scheduled for this week."
        case .logbook: "Completed and cancelled to-dos collect here."
        default: "Tap + to add a to-do."
        }
    }
}
