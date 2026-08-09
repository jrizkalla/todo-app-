import SwiftUI
import SwiftData

/// The main list pane for a sidebar destination.
struct TodoListView: View {
    let destination: ListDestination

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query private var todos: [Todo]
    @Query private var spaces: [Space]

    @Binding var selectedTodo: Todo?

    /// Incremented by the app-wide create button. The list answers by adding a
    /// row here and focusing its title — see `createTodoInCurrentList`.
    ///
    /// A counter rather than a flag so two taps in a row both register; the
    /// button lives in `RootView` and has no way to know when this finished.
    var createRequest: Binding<Int>?

    /// Set while waiting on the user's answer to the cascade prompt.
    @State private var pendingCascade: PendingCascade?
    /// Set while confirming a delete that would take other items with it.
    @State private var pendingDeletion: Todo?
    /// The to-do whose scheduling panel is open, from a leading swipe.
    @State private var schedulingTodo: Todo?

    /// What the user has typed into the pull-down search field, if anything.
    @State private var searchText = ""

    /// Suggestion chips for whichever row's title has focus.
    @State private var suggestionModel = TitleSuggestionModel()
    /// The row whose title field is focused. There is no separate edit mode.
    @FocusState private var focusedTodoID: UUID?

    @State private var importer = RemindersImporter.shared

    private var store: TodoStore { TodoStore(context: context) }

    /// Pending reminders only surface in the Inbox, which is where the spec
    /// says unorganized items collect — and not while searching, where the only
    /// rows on screen should be ones that matched.
    private var showsPendingReminders: Bool {
        destination == .inbox && !importer.pending.isEmpty && !isSearching
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
        searchableList
        // The app-wide button asks; the list is what knows how to answer.
        //
        // Ignored while searching: the results are a filtered view, and
        // something created into it would vanish the moment it failed to match
        // what is still in the field.
        .onChange(of: createRequest?.wrappedValue) { _, _ in
            guard !isSearching else { return }
            createTodoInCurrentList()
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        // Visiting a list is what "viewing" means, so its dots clear on arrival.
        .task(id: destination) { markVisibleAsViewed() }
        // Switching lists drops focus, so the keyboard never follows the user
        // to a screen they did not open it on. The query goes with it: a search
        // typed in one list has no meaning in the next.
        .onChange(of: destination) { _, _ in
            focusedTodoID = nil
            searchText = ""
        }
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
        .sheet(item: $schedulingTodo) { todo in
            SchedulePickerView(
                todo: todo,
                onPick: { date, hasTime in
                    store.update(todo) {
                        $0.assignedDate = date
                        $0.assignedHasTime = hasTime
                    }
                    schedulingTodo = nil
                },
                onAddReminder: {
                    // The full reminder editor lives in the detail view.
                    schedulingTodo = nil
                    selectedTodo = todo
                },
                onDismiss: { schedulingTodo = nil }
            )
            .presentationDetents([.medium, .large])
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

    /// The list, plus its search field.
    ///
    /// `searchable` is attached here rather than to the `ZStack` in `body`: the
    /// floating create button is the ZStack's other child, and hanging the
    /// field off the stack leaves the revealed search bar unable to take focus.
    /// Bound to the scroll view directly it behaves normally, and the
    /// pull-down gesture has the right scroll view to attach to.
    private var searchableList: some View {
        listContent
            // Hidden by default and revealed by pulling the list down, so the
            // field costs nothing until it is wanted.
            .pullDownSearchable(text: $searchText, prompt: searchPrompt)
    }

    private var listContent: some View {
        // Resolved once per redraw and passed down.
        //
        // `visibleTodos` runs the destination's whole query chain — several
        // passes over every to-do in the store — and the body referred to it
        // five separate times, so a list of any size paid that cost five times
        // for a single frame.
        rows(visibleTodos)
    }

    @ViewBuilder
    private func rows(_ visibleTodos: [Todo]) -> some View {
        if visibleTodos.isEmpty && isSearching {
            SearchEmptyState(query: searchText, scopeDescription: searchScopeDescription)
        } else if visibleTodos.isEmpty && !showsPendingReminders {
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
                            onNotesChange: { store.save() },
                            focusedTodoID: $focusedTodoID,
                            menu: { AnyView(rowMenu(for: todo)) },
                            onSubmitTitle: { createTodoAfterSubmit(from: todo) },
                            onShowDetail: { showDetail(for: todo) }
                        )
                        // On macOS the editor opens as a popover pointing at
                        // this row; on iOS this is a no-op and the detail page
                        // is pushed instead.
                        .todoDetailPopover(for: todo, selection: $selectedTodo)

                        // Subtasks nest under their parent rather than
                        // appearing as separate top-level rows — except in the
                        // Logbook, which lists finished work flat, so nesting
                        // would show a completed subtask twice.
                        ForEach(nestedSubtasks(of: todo)) { subtask in
                            TodoRow(
                                todo: subtask,
                                isSelected: selectedTodo?.uuid == subtask.uuid,
                                onToggle: { handleToggle(subtask) },
                                onSelectState: { handleSetState(subtask, to: $0) },
                                onTitleChange: { handleTitleChange($0, for: subtask) },
                                onNotesChange: { store.save() },
                                focusedTodoID: $focusedTodoID,
                                menu: { AnyView(rowMenu(for: subtask)) },
                                // Return inside a project adds another subtask
                                // to the same parent.
                                onSubmitTitle: { addSubtaskAfterSubmit(to: todo) },
                                onShowDetail: { showDetail(for: subtask) }
                            )
                            .padding(.leading, 28)
                            .todoDetailPopover(for: subtask, selection: $selectedTodo)
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
                    // Leading swipe schedules, which is the most common edit
                    // after creating something.
                    .swipeActions(edge: .leading) {
                        Button {
                            focusedTodoID = nil
                            schedulingTodo = todo
                        } label: {
                            Label("When", systemImage: "calendar")
                        }
                        .tint(.blue)
                    }
                }
                // Dragging is disabled while searching: results are ranked by
                // relevance and are a subset of several lists, so a drop
                // position there does not describe an order worth saving.
                .onMove { indices, newOffset in
                    guard !isSearching else { return }
                    var reordered = visibleTodos
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    store.reorder(reordered)
                }

                // Breathing room so the floating button never covers a row.
                Color.clear
                    .frame(height: Theme.Metrics.listBottomClearance)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            // A plain list on macOS draws flush to the pane edges, which puts
            // the checkboxes hard against the sidebar divider. The inset gives
            // the rows the same margin AppKit lists have.
            .contentMargins(
                .horizontal,
                Theme.Metrics.listContentMargin,
                for: .scrollContent
            )
            // Swiping down over the list dismisses the keyboard raised by
            // inline title editing.
            .scrollDismissesKeyboard(.interactively)
            .animation(Theme.Animation.listChange, value: visibleTodos.map(\.uuid))
        }
    }

    /// The "nothing here" screen.
    ///
    /// Explicitly stretched to fill the pane. `ContentUnavailableView` sizes
    /// itself to its content, and the create button is an overlay aligned to
    /// this view's frame — so without the stretch the button pinned itself to
    /// the bottom-right of the *message*, leaving it floating mid-pane instead
    /// of in the corner of the window.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: destination.symbolName)
        } description: {
            Text(emptyMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Create a to-do belonging to the list currently on screen, and put the
    /// cursor in its title.
    ///
    /// The scheduling context comes from the destination, so a to-do added from
    /// Today is scheduled for today and one added inside a project belongs to
    /// that project — rather than everything landing in the Inbox.
    @discardableResult
    private func createTodoInCurrentList() -> Todo {
        let created = store.createTodo(
            space: defaultSpace,
            parent: defaultParent,
            assignedDate: defaultAssignedDate
        )
        focusedTodoID = created.uuid
        return created
    }

    /// Create the next to-do after Return, once the field has committed.
    ///
    /// Moving focus in the same runloop pass as `onSubmit` drops the keystroke
    /// still in flight — the last character typed before Return never reaches
    /// the binding. Deferring by one turn lets it land first.
    private func createTodoAfterSubmit(from todo: Todo) {
        DispatchQueue.main.async {
            store.save()
            createTodoInCurrentList()
        }
    }

    /// Same deferral for a subtask created with Return inside a project.
    private func addSubtaskAfterSubmit(to parent: Todo) {
        DispatchQueue.main.async {
            store.save()
            let subtask = store.addSubtask(to: parent)
            focusedTodoID = subtask.uuid
        }
    }

    /// Open the detail view, dropping focus so the keyboard does not follow.
    private func showDetail(for todo: Todo) {
        focusedTodoID = nil
        selectedTodo = todo
    }

    @ViewBuilder
    private func rowMenu(for todo: Todo) -> some View {
        ControlGroup {
            StatusPicker(current: todo.state, tint: todo.color) { state in
                handleSetState(todo, to: state)
            }
        }.controlGroupStyle(.menu)
        
        Divider()
        // A first tap edits the title in place; the full editor is here and on
        // a second tap of an already-focused row.
        Button {
            showDetail(for: todo)
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

    /// Subtasks to draw beneath a row, empty where the list is already flat.
    private func nestedSubtasks(of todo: Todo) -> [Todo] {
        ListRowComposition.nestedSubtasks(
            of: todo,
            destination: destination,
            isSearching: isSearching
        )
    }

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
        if let previous {
            // Deferred, because the title blurring does not by itself mean the
            // user left the row: tapping the row's inline notes field blurs the
            // title one turn before the notes field takes focus. Discarding an
            // untitled row on that transient reading would delete the to-do out
            // from under someone who was only reaching for its notes.
            DispatchQueue.main.async {
                guard focusedTodoID != previous else { return }
                guard let todo = todos.first(where: { $0.uuid == previous }) else { return }
                // Notes typed into a still-untitled row are content too, so the
                // row has earned its place even without a title.
                let isBlank = todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && todo.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if isBlank {
                    store.delete(todo)
                } else {
                    store.update(todo) { _ in }
                }
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

    /// Whether the search field currently holds something worth filtering on.
    private var isSearching: Bool {
        TodoSearch.isActive(searchText)
    }

    private var visibleTodos: [Todo] {
        // A search replaces the list rather than narrowing what is already
        // there: the destination decides the *pool* to search, so searching
        // inside a project finds work anywhere in it, not only the handful of
        // rows that happened to pass the date filter.
        if isSearching {
            return TodoSearch.matches(todos, query: searchText, in: destination)
        }

        // Keeps the focused row on screen even once it stops matching this list
        // — accepting "Schedule tomorrow" in Today would otherwise yank the row
        // out from under the cursor mid-word — without duplicating a focused
        // subtask that is already drawn nested under its parent.
        return ListRowComposition.rows(
            filtered: filteredTodos,
            focused: focusedTodo,
            destination: destination,
            isSearching: isSearching
        )
    }

    private var filteredTodos: [Todo] {
        switch destination {
        case .inbox: TodoQueries.inbox(todos, includeResolved: settings.showResolved)
        case .today: TodoQueries.today(todos, calendar: AppSettings.shared.calendar, includeResolved: settings.showResolved)
        case .thisWeek: TodoQueries.thisWeek(todos, calendar: AppSettings.shared.calendar, includeResolved: settings.showResolved)
        case .anytime: TodoQueries.anytime(todos, includeResolved: settings.showResolved)
        case .logbook: TodoQueries.logbook(todos)
        case .space(let id): TodoQueries.inSpace(todos, spaceID: id, includeResolved: settings.showResolved)
        case .project(let id): TodoQueries.inProject(todos, projectID: id, includeResolved: settings.showResolved)
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

    /// Placeholder naming what this field searches, since the same gesture in
    /// two different lists searches two different things.
    private var searchPrompt: String {
        switch destination {
        case .logbook: "Search Logbook"
        case .space, .project: "Search \(title)"
        default: "Search \(destination.title)"
        }
    }

    /// Fills the blank in "Nothing ⟨…⟩ matches" on the no-results screen.
    private var searchScopeDescription: String {
        switch destination {
        case .logbook: "in the Logbook"
        case .space, .project: "in “\(title)”"
        default: "in \(destination.title)"
        }
    }

    /// Show the space badge on cross-cutting lists where items come from
    /// several places.
    private var showsSpaceBadge: Bool {
        // Results from the Inbox's field can come from anywhere, so the badge
        // earns its place there too while a search is running.
        if isSearching { return true }

        return switch destination {
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
        // Both lists are date-driven, so something created there should land in
        // them rather than dropping into the Inbox. Today is the natural date
        // for This Week too — it is inside the week and needs no guessing.
        case .today, .thisWeek:
            Calendar.current.startOfDay(for: Date())
        // Anytime means scheduled-but-undated, which the bucket rules give a
        // to-do once it has a home; a date would move it into Today.
        default:
            nil
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
