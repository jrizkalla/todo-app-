import SwiftUI
import SwiftData

/// A list's own calendar, pushed on top of it.
///
/// A wrapper rather than pushing the `ListDestination` directly: the list
/// already navigates on to-dos, and a bare destination value would be
/// indistinguishable from any other route carrying one.
struct CalendarRoute: Hashable {
    let destination: ListDestination
}

/// The main list pane for a sidebar destination.
/// The list pane, wrapped so its query can be rebuilt.
///
/// A `@Query`'s predicate is fixed when the view is initialized, but two things
/// it depends on — the destination and the Show Resolved preference — both
/// change while the app is running. This wrapper gives the inner view an
/// identity built from those, so SwiftUI recreates it (and with it the query)
/// whenever either moves. Without this the list would keep answering with the
/// previous destination's predicate.
struct TodoListView: View {
    let destination: ListDestination

    @Environment(AppSettings.self) private var settings

    @Binding var selectedTodo: Todo?
    var createRequest: Binding<Int>?
    var capturedTodo: Binding<UUID?>?

    var body: some View {
        DestinationTodoList(
            destination: destination,
            includeResolved: settings.showResolved,
            selectedTodo: $selectedTodo,
            createRequest: createRequest,
            capturedTodo: capturedTodo
        )
        .id(QueryIdentity(destination: destination, includeResolved: settings.showResolved))
    }

    /// What the row query is built from. A change to either rebuilds it.
    private struct QueryIdentity: Hashable {
        let destination: ListDestination
        let includeResolved: Bool
    }
}

private struct DestinationTodoList: View {
    let destination: ListDestination

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings

    /// This destination's rows, filtered and sorted by SQLite.
    ///
    /// The query carries the destination's `#Predicate` (see `TodoQueries`)
    /// rather than fetching every to-do in the store and narrowing it in the
    /// body. It stays a `@Query` rather than becoming a plain `context.fetch`
    /// because that is what keeps the list live: SwiftUI re-runs a `@Query`
    /// when the store changes, and a fetch in a computed property would go
    /// stale after every edit.
    ///
    /// The residual in-memory passes that no predicate can express — cycle
    /// filtering, and the `assignedDate ?? dueDate` ordering — are applied to
    /// this already-narrowed page in `filteredTodos`.
    @Query private var destinationTodos: [Todo]
    /// Every space, in display order.
    ///
    /// Sorted by SQLite rather than re-sorted at each use site. Deliberately
    /// *not* Focus-filtered: hiding a space from the sidebar says what the user
    /// is looking at now, not where work is allowed to be filed.
    @Query(TodoQueries.allSpacesDescriptor())
    private var spaces: [Space]

    @Binding var selectedTodo: Todo?

    /// Incremented by the app-wide create button. The list answers by adding a
    /// row here and focusing its title — see `createTodoInCurrentList`.
    ///
    /// A counter rather than a flag so two taps in a row both register; the
    /// button lives in `RootView` and has no way to know when this finished.
    var createRequest: Binding<Int>?

    /// A to-do just captured with Cmd+N, to be selected with its title focused.
    ///
    /// Only the Inbox is given this, since that is where Cmd+N puts things —
    /// see `RootView.captureIntoInbox`. Cleared once claimed.
    var capturedTodo: Binding<UUID?>?

    /// Builds the row query from the destination and the resolved preference.
    ///
    /// A `@Query`'s descriptor is fixed at initialization, which is why the
    /// wrapper above gives this view an identity that changes whenever either
    /// input does — that is what recreates it, and rebuilds the query.
    init(
        destination: ListDestination,
        includeResolved: Bool,
        selectedTodo: Binding<Todo?>,
        createRequest: Binding<Int>? = nil,
        capturedTodo: Binding<UUID?>? = nil
    ) {
        self.destination = destination
        self._selectedTodo = selectedTodo
        self.createRequest = createRequest
        self.capturedTodo = capturedTodo

        _destinationTodos = Query(
            TodoQueries.descriptor(
                for: destination,
                calendar: AppSettings.shared.calendar,
                includeResolved: includeResolved
            )
        )
    }

    /// Set while waiting on the user's answer to the cascade prompt.
    @State private var pendingCascade: PendingCascade?
    /// Set while confirming a delete that would take other items with it.
    @State private var pendingDeletion: Todo?
    /// The to-do whose scheduling panel is open, from a leading swipe.
    @State private var schedulingTodo: Todo?
    /// True when the scheduling panel was opened from the keyboard, which is
    /// what earns it the typed-date field.
    @State private var schedulingFromKeyboard = false
    /// The to-do whose "move to" picker is open, from Cmd+M.
    @State private var movingTodo: Todo?

    /// Where the arrow keys are pointing.
    ///
    /// Separate from `focusedTodoID`, which is text-field focus: a row can be
    /// keyboard-selected without the caret being in its title, and that
    /// distinction is what lets Cmd+K toggle a row rather than typing into it.
    @State private var cursor = KeyboardCursor()
    /// The last row order the cursor was reconciled against, so a row vanishing
    /// can be resolved to its nearest surviving neighbour.
    @State private var lastRowOrder: [UUID] = []

    /// What the user has typed into the pull-down search field, if anything.
    @State private var searchText = ""

    /// Set while this list's calendar is pushed on top of it.
    @State private var calendarRoute: CalendarRoute?

    /// Suggestion chips for whichever row's title has focus.
    @State private var suggestionModel = TitleSuggestionModel()
    /// Debounces the save and suggestion refresh behind title editing.
    @State private var titleEditTask: Task<Void, Never>?
    @State private var notesEditTask: Task<Void, Never>?
    /// The row whose title field is focused. There is no separate edit mode.
    @FocusState private var focusedTodoID: UUID?
    /// Whether the search field holds the keyboard, so Cmd+F can put it there.
    @FocusState private var isSearchFocused: Bool

    /// Whether the list pane itself holds the keyboard.
    ///
    /// `onKeyPress` only delivers to a *focused* view, and a `List` full of
    /// text fields never takes focus on its own — so without somewhere for the
    /// pane's own focus to live, the arrow keys were being dropped on the floor
    /// whenever the caret was not in a title. Selecting a row hands focus here,
    /// which is what makes the arrows work after a tap or a Cmd+F escape.
    @FocusState private var isListFocused: Bool

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
        droppableList
        // The app-wide button asks; the list is what knows how to answer.
        //
        // Ignored while searching: the results are a filtered view, and
        // something created into it would vanish the moment it failed to match
        // what is still in the field.
        .onChange(of: createRequest?.wrappedValue) { _, _ in
            guard !isSearching else { return }
            // The list stays alive underneath its pushed calendar, so both
            // would answer the one button and a single tap would create two
            // to-dos. Whichever is on top is the one the user meant.
            guard !isShowingCalendar else { return }
            createTodoInCurrentList()
        }
        // Cmd+N created the to-do already, in the Inbox; this list only has to
        // put the caret in it. Unlike `createRequest` there is nothing to
        // create here — the shortcut works from tabs that have no list at all,
        // so `RootView` does the creating and hands the row over.
        .onChange(of: capturedTodo?.wrappedValue) { _, captured in
            guard let captured, !isShowingCalendar else { return }
            withAnimation(Theme.Animation.rowExpand) { cursor.select(captured) }
            focusedTodoID = captured
            capturedTodo?.wrappedValue = nil
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            // Only spaces and projects get one: the cross-cutting lists are
            // already covered by the Calendar tab, which shows the same days
            // unscoped, so a second entry point onto it would just be a
            // duplicate.
            if showsCalendarButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Focus belongs to the calendar now; a caret left in a
                        // row's title would keep the keyboard up over the grid.
                        focusedTodoID = nil
                        calendarRoute = CalendarRoute(destination: destination)
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                    .help("Show \(title) on a calendar")
                }
            }
        }
        // Pushed rather than presented: it is the same list seen another way,
        // so Back returns to the rows it was opened from.
        .navigationDestination(item: $calendarRoute) { route in
            CalendarView(
                selectedTodo: $selectedTodo,
                destination: route.destination,
                createRequest: createRequest,
                onShowList: { calendarRoute = nil }
            )
            .todoDetailDestination(selection: $selectedTodo)
        }
        // A calendar opened from one list has no meaning in the next.
        .onChange(of: destination) { _, _ in calendarRoute = nil }
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
            // Typing in a row is also a way of choosing it, so the cursor
            // follows the caret. Without this, Cmd+K after clicking into a
            // title would act on whatever the arrows last pointed at.
            if let current { cursor.select(current) }
        }
        // The pane has to be focusable for `onKeyPress` to reach it at all; the
        // key handlers below are attached to this same view so they fire while
        // the list — rather than one of its title fields — holds the keyboard.
        .focusable()
        .focused($isListFocused)
        // The focus this takes is a plumbing detail — it exists so the arrow
        // keys have somewhere to land — and is not a thing the user selected.
        // On macOS the system drew it as a ring around the entire pane, so
        // tapping one row lit up the whole list along with it.
        .focusEffectDisabled()
        // Arrow keys drive the cursor whenever the caret is not in a text
        // field — in a field the arrows belong to the text, which is why this
        // defers rather than competing for them.
        .onKeyPress(.upArrow) { moveCursor(.up) }
        .onKeyPress(.downArrow) { moveCursor(.down) }
        // Return opens whatever the cursor is on, matching a double-click.
        .onKeyPress(.return) {
            guard focusedTodoID == nil, let todo = cursorTodo else { return .ignored }
            showDetail(for: todo)
            return .handled
        }
        .keyboardCommands(isActive: isKeyboardTarget) { command in
            perform(command)
        }
        // Keeps the cursor on something real as rows come and go.
        .onChange(of: visibleRowOrder) { previous, current in
            cursor.reconcile(with: current, previousOrder: previous)
            lastRowOrder = current
        }
        // A cursor from one list means nothing in the next.
        .onChange(of: destination) { _, _ in cursor.select(nil) }
        // Chips for the focused title field sit above the keyboard on iOS and
        // at the window bottom on macOS, the same as in the detail editor.
        .suggestionBar(suggestionModel.suggestions) { suggestion in
            guard let todo = focusedTodo else { return }
            suggestionModel.apply(suggestion, to: todo, context: context, store: store)
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
                onDismiss: { schedulingTodo = nil },
                acceptsTypedDate: schedulingFromKeyboard
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $movingTodo) { todo in
            MoveDestinationView(
                todo: todo,
                onPick: { destination in
                    apply(destination, to: todo)
                    movingTodo = nil
                },
                onDismiss: { movingTodo = nil }
            )
            .presentationDetents([.medium])
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

    /// The pane accepts drops too, so a to-do can be dragged from the Inbox
    /// panel onto whatever list is open without aiming at its sidebar row.
    ///
    /// Attached to the whole pane rather than to the rows: dropping *between*
    /// two rows is the same intent as dropping on the list, and a target that
    /// only covered the rows would leave the empty space below them dead.
    private var droppableList: some View {
        searchableList
            .todoDropTarget(
                destination,
                store: store
            )
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
            .pullDownSearchable(
                text: $searchText,
                prompt: searchPrompt,
                isFocused: $isSearchFocused
            )
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

    #if os(macOS)
    private let rowInsets = EdgeInsets(top: 10, leading: 5, bottom: 10, trailing: 5)
    #else
    private let rowInsets = EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
    #endif
    
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
                            // The cursor is the expanded row. Deliberately not
                            // `selectedTodo`: that binding *presents the
                            // editor* — it pushes the detail page on iOS and
                            // opens the popover on macOS — so expanding a row
                            // through it skipped the first stage of the tap
                            // and opened the detail on a single tap.
                            isSelected: cursor.selection == todo.uuid,
                            onToggle: { _ in handleToggle(todo) },
                            onSelectState: { handleSetState(todo, to: $0) },
                            onTitleChange: { handleTitleChange($0, for: todo) },
                            onNotesChange: { _ in store.save() },
                            menu: { AnyView(rowMenu(for: todo)) },
                            onSubmitTitle: { createTodoAfterSubmit(from: todo) },
                            onShowDetail: { _ in showDetail(for: todo) },
                            focusedTodoID: $focusedTodoID
                        )
                        // The tap that expands a row is attached here rather
                        // than inside the row, which captures no taps of its
                        // own: only the list knows that expanding is also a
                        // cursor move, and only it can leave the already
                        // expanded row alone so a second tap reaches the title
                        // field instead of being swallowed.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard cursor.selection != todo.uuid else { return }
                            withAnimation(Theme.Animation.rowExpand) { selectRow(todo) }
                        }
                        // A row in any list can be dragged to any other list,
                        // to a space or project in the sidebar, or onto the
                        // calendar. Suppressed while the row's title has the
                        // caret, where a press belongs to the text field —
                        // see `TodoDraggableModifier`.
                        .todoDraggable(todo, isEnabled: focusedTodoID != todo.uuid)
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
                                showsSpace: false,
                                isSelected: cursor.selection == subtask.uuid,
                                onToggle: { _ in handleToggle(subtask) },
                                onSelectState: { handleSetState(subtask, to: $0) },
                                onTitleChange: { _ in },
                                onNotesChange: { _ in },
//                                onTitleChange: { print("title change"); handleTitleChange($0, for: subtask) },
//                                onNotesChange: { print("notes change"); handleNotesChange(for: $0) },
                                menu: { AnyView(rowMenu(for: subtask)) },
                                // Return inside a project adds another subtask
                                // to the same parent.
                                onSubmitTitle: { addSubtaskAfterSubmit(to: todo) },
                                onShowDetail: { _ in showDetail(for: subtask) },
                                focusedTodoID: $focusedTodoID
                            )
                            .padding(.leading, 28)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard cursor.selection != subtask.uuid else { return }
                                withAnimation(Theme.Animation.rowExpand) { selectRow(subtask) }
                            }
                            // Dragging a subtask out is how it leaves its
                            // parent — the drop destinations already detach it,
                            // so this is the gesture for promoting work out of
                            // a project as well as for scheduling it.
                            .todoDraggable(subtask, isEnabled: focusedTodoID != subtask.uuid)
                            .todoDetailPopover(for: subtask, selection: $selectedTodo)
                        }
                    }
                    .listRowInsets(
                        rowInsets
                    )
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
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .decelerating {
                    clearSelection()
                }
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
        // The cursor moves with the caret. A row is only drawn expanded — and
        // its title field only accepts the keyboard — when the cursor is on it,
        // so focusing a row the cursor had not reached left the new to-do
        // collapsed and swallowed everything typed into it.
        cursor.select(created.uuid)
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
            cursor.select(subtask.uuid)
            focusedTodoID = subtask.uuid
        }
    }

    /// Open the detail view, dropping focus so the keyboard does not follow.
    private func showDetail(for todo: Todo) {
        focusedTodoID = nil
        selectedTodo = todo
    }

    // MARK: Keyboard

    /// A first tap on a row: select it, without putting the caret in its title.
    ///
    /// Selection and text focus are the same idea from the user's side — "this
    /// is the to-do I mean" — so a tap moves the same cursor the arrow keys
    /// drive rather than introducing a third notion of which row is current.
    /// Any caret elsewhere is dropped, since the tap has moved on from it.
    private func selectRow(_ todo: Todo) {
        focusedTodoID = nil
        cursor.select(todo.uuid)
        // Taking the keyboard here is what lets the arrow keys continue from
        // the row just tapped. Without it the pane has a cursor nothing is
        // listening for, and the arrows do nothing until something else
        // happens to focus the list.
        isListFocused = true
    }

    /// Put the selection down, after a tap that landed outside every row.
    ///
    /// The caret goes with it: a row that is no longer selected collapses, and
    /// leaving focus in a collapsed row's title would keep the keyboard up over
    /// a field the user can no longer see.
    private func clearSelection() {
        guard cursor.selection != nil || focusedTodoID != nil else { return }
        focusedTodoID = nil
        withAnimation(Theme.Animation.rowExpand) { cursor.select(nil) }
    }

    /// Every row the arrow keys can land on, parents and their nested subtasks
    /// in the order they are drawn.
    ///
    /// Built from the same composition the list renders, so the cursor walks
    /// exactly what is on screen — including a subtask nested under its parent,
    /// which is a row the user can see and therefore expects to reach.
    private var visibleRowOrder: [UUID] {
        visibleTodos.flatMap { [$0.uuid] + nestedSubtasks(of: $0).map(\.uuid) }
    }

    private var cursorTodo: Todo? {
        guard let id = cursor.selection else { return nil }
        return TodoQueries.todo(uuid: id, in: context)
    }

    /// The to-do a keyboard command should act on.
    ///
    /// The cursor first, falling back to the row being edited — someone who
    /// clicked into a title and hit Cmd+S means *that* row, even if the arrows
    /// were never used.
    private var commandTarget: Todo? {
        cursorTodo ?? focusedTodo ?? selectedTodo
    }

    /// Whether this list should be answering keyboard commands.
    ///
    /// A list that is off-screen still exists — every tab's view stays alive
    /// once visited — so without a gate all of them would respond to one
    /// keystroke at once.
    private var isKeyboardTarget: Bool {
        // The pushed calendar answers the same commands and shares
        // `selectedTodo` with this list, so the list stands down while it is on
        // top rather than both acting on one keystroke.
        guard !isShowingCalendar else { return false }
        return cursor.selection != nil || focusedTodoID != nil || selectedTodo != nil
    }

    /// Move the keyboard cursor, unless a text field wants the arrow key.
    private func moveCursor(_ direction: KeyboardCursor.Direction) -> KeyPress.Result {
        guard focusedTodoID == nil else { return .ignored }

        var next = cursor
        guard next.move(direction, in: visibleRowOrder) else { return .ignored }

        cursor = next
        // Selecting a row also makes it the detail target on macOS, where the
        // popover is anchored to the selected row.
        return .handled
    }

    /// Run a keyboard command against whatever the cursor is on.
    private func perform(_ command: KeyboardCommand) {
        switch command {
        case .create:
            guard !isSearching else { return }
            createTodoInCurrentList()

        case .search:
            // Focus belongs to the field now, not to a row.
            focusedTodoID = nil
            isSearchFocused = true

        case .schedule:
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            schedulingFromKeyboard = true
            schedulingTodo = todo

        case .toggleDone:
            guard let todo = commandTarget else { return }
            handleToggle(todo)

        case .showDetail:
            guard let todo = commandTarget else { return }
            showDetail(for: todo)

        case .move:
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            movingTodo = todo

        case .duplicate:
            guard let todo = commandTarget else { return }
            duplicate(todo)

        case .delete:
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            requestDelete(todo)
        }
    }

    /// Copy a to-do and move the cursor onto the copy.
    ///
    /// The cursor follows the new row rather than staying on the original: the
    /// copy is what the user is about to edit — that is the point of
    /// duplicating — and it lands directly below, so the selection moving one
    /// row is what they would expect to see.
    private func duplicate(_ todo: Todo) {
        let copy = store.duplicate(todo)
        withAnimation(Theme.Animation.listChange) { cursor.select(copy.uuid) }
    }

    /// Apply a picked move destination.
    private func apply(_ destination: MoveDestinationView.Destination, to todo: Todo) {
        switch destination {
        case .none:
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: nil)
        case .space(let id):
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: spaces.first { $0.uuid == id })
        case .project(let id):
            guard let project = TodoQueries.todo(uuid: id, in: context) else { return }
            _ = store.adopt(todo, asSubtaskOf: project)
        }
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
            duplicate(todo)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square.dashed")
        }

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
            ForEach(spaces) { space in
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
    /// React to a keystroke in a row's title.
    ///
    /// Neither half of this runs inline any more. Saving wrote the whole
    /// context to disk on *every character*, and refreshing the suggestions
    /// rescanned every to-do to rebuild the parser's project list — together
    /// they made typing visibly stutter. The edit is already live in the model
    /// object; what is deferred is only persisting it and re-deriving the
    /// chips, neither of which the next keystroke depends on.
    ///
    /// The row is still saved promptly on blur, via `handleFocusChange`.
    private func handleTitleChange(_ newTitle: String, for todo: Todo) {
        titleEditTask?.cancel()
        titleEditTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            suggestionModel.refresh(for: newTitle, todo: todo, context: context)
            store.save()
        }
    }
    
    private func handleNotesChange(for todo: Todo) {
        notesEditTask?.cancel()
        notesEditTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            
            store.save()
        }
    }

    /// React to focus moving between rows.
    ///
    /// Leaving a row is the moment to refile it and to discard it if it was
    /// never given a title — the empty row a user creates and then abandons.
    private func handleFocusChange(from previous: UUID?, to current: UUID?) {
        // The debounced save is about to be superseded: leaving the row either
        // saves it outright below or deletes it, and a queued write must not
        // land against a to-do that no longer exists.
        titleEditTask?.cancel()

        if let previous {
            // Deferred, because the title blurring does not by itself mean the
            // user left the row: tapping the row's inline notes field blurs the
            // title one turn before the notes field takes focus. Discarding an
            // untitled row on that transient reading would delete the to-do out
            // from under someone who was only reaching for its notes.
            DispatchQueue.main.async {
                guard focusedTodoID != previous else { return }
                guard let todo = TodoQueries.todo(uuid: previous, in: context) else { return }
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

        guard let current, let todo = TodoQueries.todo(uuid: current, in: context) else {
            suggestionModel.clear()
            return
        }
        suggestionModel.refresh(for: todo.title, todo: todo, context: context)
    }

    /// The todo whose title has focus, for the suggestion bar.
    private var focusedTodo: Todo? {
        guard let id = focusedTodoID else { return nil }
        return TodoQueries.todo(uuid: id, in: context)
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
            return TodoSearch.matches(query: searchText, in: destination, context: context)
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

    /// The destination's rows: what the query returned, plus the rules that
    /// could not be predicates. See `destinationTodos` and `TodoQueries.finish`.
    private var filteredTodos: [Todo] {
        TodoQueries.finish(destinationTodos, for: destination)
    }

    private var title: String {
        switch destination {
        case .space(let id):
            spaces.first { $0.uuid == id }?.name ?? "Space"
        case .project(let id):
            TodoQueries.todo(uuid: id, in: context)?.title ?? "Project"
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

    /// Whether this list offers a calendar of its own.
    ///
    /// Spaces and projects only. The date-driven lists — Today, Tomorrow, This
    /// Week — are already what the Calendar tab shows, and the Inbox and
    /// Anytime hold work with no date to lay out, so a grid of them would be
    /// empty by definition.
    private var showsCalendarButton: Bool {
        switch destination {
        case .space, .project: true
        default: false
        }
    }

    /// Whether the pushed calendar is the screen the user is looking at.
    private var isShowingCalendar: Bool { calendarRoute != nil }

    /// Show the space badge on cross-cutting lists where items come from
    /// several places.
    private var showsSpaceBadge: Bool {
        // Results from the Inbox's field can come from anywhere, so the badge
        // earns its place there too while a search is running.
        if isSearching { return true }

        return switch destination {
        case .today, .tomorrow, .thisWeek, .anytime, .logbook: true
        default: false
        }
    }

    /// A todo created inside a space or project belongs there.
    private var defaultSpace: Space? {
        if case .space(let id) = destination {
            return spaces.first { $0.uuid == id }
        }
        if case .project(let id) = destination {
            return TodoQueries.todo(uuid: id, in: context)?.space
        }
        return nil
    }

    private var defaultParent: Todo? {
        if case .project(let id) = destination {
            return TodoQueries.todo(uuid: id, in: context)
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
        // Same rule one day on: something added to Tomorrow has to land there
        // rather than in Today, or the row vanishes the moment it is created.
        case .tomorrow:
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
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
        case .tomorrow: "Nothing Tomorrow"
        case .thisWeek: "Nothing This Week"
        case .logbook: "No History Yet"
        default: "Nothing Here"
        }
    }

    private var emptyMessage: String {
        switch destination {
        case .inbox: "New to-dos land here until you give them a date or a home."
        case .today: "Tap + to add something for today."
        case .tomorrow: "Tap + to add something for tomorrow."
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

#Preview("Tomorrow") {
    TodoListPreviewHost(destination: .tomorrow)
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
