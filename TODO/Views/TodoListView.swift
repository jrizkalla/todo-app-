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
    /// Set while confirming a delete that would take other items with it.
    @State private var pendingDeletion: Todo?

    /// Suggestion chips for whichever row's title has focus.
    @State private var suggestionModel = TitleSuggestionModel()
    /// The row whose title field is focused. There is no separate edit mode.
    @FocusState private var focusedTodoID: UUID?

    @State private var importer = RemindersImporter.shared

    private var store: TodoStore { TodoStore(context: context) }

    /// Pending reminders only surface in the Inbox, which is where the spec
    /// says unorganized items collect.
    private var showsPendingReminders: Bool {
        destination == .inbox && !importer.pending.isEmpty
    }

    /// A blocked state change awaiting confirmation, per the spec's rule that
    /// the app should ask before resolving a parent's subtasks.
    private struct PendingCascade: Identifiable {
        let id = UUID()
        let todo: Todo
        let target: CompletionState
        let blockedCount: Int
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            listContent
            createButton
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        // Visiting a list is what "viewing" means, so its dots clear on arrival.
        .task(id: destination) { markVisibleAsViewed() }
        // Switching lists drops focus, so the keyboard never follows the user
        // to a screen they did not open it on.
        .onChange(of: destination) { _, _ in focusedTodoID = nil }
        .onChange(of: focusedTodoID) { previous, current in
            handleFocusChange(from: previous, to: current)
        }
        // Chips for the focused title field sit above the keyboard on iOS and
        // at the window bottom on macOS, the same as in the detail editor.
        .suggestionBar(suggestionModel.suggestions) { suggestion in
            guard let todo = focusedTodo else { return }
            suggestionModel.apply(suggestion, to: todo, allTodos: todos, store: store)
        }
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
        .confirmationDialog(
            deletePrompt,
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let todo = pendingDeletion {
                Button("Delete", role: .destructive) {
                    store.delete(todo)
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if visibleTodos.isEmpty && !showsPendingReminders {
            emptyState
        } else {
            List {
                // Waiting in the Reminders app, not yet copied here.
                if showsPendingReminders {
                    Section {
                        ForEach(importer.pending) { reminder in
                            PendingReminderRow(reminder: reminder) {
                                withAnimation(Theme.Animation.listChange) {
                                    _ = importer.importReminder(id: reminder.id, into: context)
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        PendingRemindersHeader(count: importer.pending.count) {
                            withAnimation(Theme.Animation.listChange) {
                                _ = importer.importAll(into: context)
                            }
                        }
                    }
                }

                ForEach(visibleTodos) { todo in
                    VStack(spacing: 0) {
                        TodoRow(
                            todo: todo,
                            showsSpace: showsSpaceBadge,
                            isSelected: selectedTodo?.uuid == todo.uuid,
                            onToggle: { handleToggle(todo) },
                            onSelectState: { handleSetState(todo, to: $0) },
                            onTitleChange: { handleTitleChange($0, for: todo) },
                            focusedTodoID: $focusedTodoID,
                            menu: { AnyView(rowMenu(for: todo)) }
                        )

                        // Subtasks nest under their parent rather than
                        // appearing as separate top-level rows.
                        ForEach(todo.orderedSubtasks) { subtask in
                            TodoRow(
                                todo: subtask,
                                isSelected: selectedTodo?.uuid == subtask.uuid,
                                onToggle: { handleToggle(subtask) },
                                onSelectState: { handleSetState(subtask, to: $0) },
                                onTitleChange: { handleTitleChange($0, for: subtask) },
                                focusedTodoID: $focusedTodoID,
                                menu: { AnyView(rowMenu(for: subtask)) }
                            )
                            .padding(.leading, 28)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            requestDelete(todo)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
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
            // Swiping down over the list dismisses the keyboard raised by
            // inline title editing.
            .scrollDismissesKeyboard(.interactively)
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

    /// Floating create button.
    ///
    /// Creating a to-do adds it to the current list and puts the cursor in its
    /// title. The detail page is reached from the long-press menu instead.
    private var createButton: some View {
        Button {
            let created = store.createTodo(
                space: defaultSpace,
                parent: defaultParent,
                assignedDate: defaultAssignedDate
            )
            focusedTodoID = created.uuid
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
        .padding(.trailing, 22)
        .padding(.bottom, 22)
        .accessibilityLabel("New To-Do")
        .keyboardShortcut("n", modifiers: .command)
    }

    @ViewBuilder
    private func rowMenu(for todo: Todo) -> some View {
        // Tapping a row edits its title in place, so the full editor lives
        // here.
        Button {
            focusedTodoID = nil
            selectedTodo = todo
        } label: {
            Label("Show Details", systemImage: "info.circle")
        }

        Divider()

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
            requestDelete(todo)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Deleting

    /// Delete outright, or ask first when the delete would take more with it.
    ///
    /// A plain to-do with nothing attached is a cheap mistake to undo by
    /// retyping, so it goes immediately. A project or a parent takes its
    /// children down with it, which is not obvious from the row alone.
    private func requestDelete(_ todo: Todo) {
        if todo.subtaskList.isEmpty {
            store.delete(todo)
        } else {
            pendingDeletion = todo
        }
    }

    private var deletePrompt: String {
        guard let todo = pendingDeletion else { return "" }
        let count = todo.subtaskList.count
        let noun = count == 1 ? "subtask" : "subtasks"
        let kind = todo.isProject ? "project" : "to-do"
        return "Deleting this \(kind) also deletes its \(count) \(noun). This cannot be undone."
    }

    // MARK: Viewed tracking

    /// Clear the new flag on everything this list is showing, including the
    /// nested subtasks, which are on screen too.
    ///
    /// Keyed on the destination alone, so it runs when the user *arrives* at a
    /// list. Something landing in a list already on screen — an import, or a
    /// sync — keeps its dot until the user comes back, which is what makes the
    /// dot worth having.
    private func markVisibleAsViewed() {
        let shown = visibleTodos.flatMap { [$0] + $0.orderedSubtasks }
        store.markAsViewed(shown)
    }

    // MARK: Title editing

    /// Save as the user types, and keep the chips tracking the current title.
    ///
    /// There is nothing to "commit": edits land in the store immediately, so
    /// leaving the screen mid-word loses nothing.
    private func handleTitleChange(_ newTitle: String, for todo: Todo) {
        suggestionModel.refresh(for: newTitle, todo: todo, allTodos: todos)
        store.save()
    }

    /// React to focus moving between rows.
    ///
    /// Leaving a row is the moment to refile it and to discard it if it was
    /// never given a title — the empty row a user creates and then abandons.
    private func handleFocusChange(from previous: UUID?, to current: UUID?) {
        if let previous, let todo = todos.first(where: { $0.uuid == previous }) {
            if todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.delete(todo)
            } else {
                store.update(todo) { _ in }
            }
        }

        guard let current, let todo = todos.first(where: { $0.uuid == current }) else {
            suggestionModel.clear()
            return
        }
        suggestionModel.refresh(for: todo.title, todo: todo, allTodos: todos)
    }

    /// The todo whose title has focus, for the suggestion bar.
    private var focusedTodo: Todo? {
        guard let id = focusedTodoID else { return nil }
        return todos.first { $0.uuid == id }
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
        var result = filteredTodos

        // Keep the focused row on screen even once it stops matching this list
        // — accepting "Schedule tomorrow" in Today would otherwise yank the row
        // out from under the cursor mid-word. It drops out once focus leaves.
        if let focused = focusedTodo, !result.contains(where: { $0.uuid == focused.uuid }) {
            result.append(focused)
        }
        return result
    }

    private var filteredTodos: [Todo] {
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

#if DEBUG
/// Hosts the selection binding the list needs.
private struct TodoListPreviewHost: View {
    let destination: ListDestination
    @State private var selected: Todo?

    var body: some View {
        NavigationStack {
            TodoListView(destination: destination, selectedTodo: $selected)
        }
    }
}

#Preview("Today") {
    TodoListPreviewHost(destination: .today)
        .previewEnvironment()
}

#Preview("Inbox") {
    TodoListPreviewHost(destination: .inbox)
        .previewEnvironment()
}

#Preview("Project") {
    // A project shows its subtasks nested under it.
    TodoListPreviewHost(destination: .project(PreviewData.project.uuid))
        .previewEnvironment()
}

#Preview("Logbook") {
    TodoListPreviewHost(destination: .logbook)
        .previewEnvironment()
}

#Preview("Empty") {
    // The empty state, which has its own copy per destination.
    TodoListPreviewHost(destination: .anytime)
        .modelContainer(for: AppSchema.models, inMemory: true)
        .environment(AppSettings.shared)
}
#endif
