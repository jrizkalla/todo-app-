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

    /// The window this list belongs to, so a menu command aimed at another
    /// window is not answered here as well.
    var windowID: UUID?

    /// Whether this list is the one the user is looking at.
    ///
    /// Every tab's view stays alive once visited, so "exists" and "is on
    /// screen" are different questions, and the commands that act on the open
    /// screen — Cmd+N, Cmd+F — have to ask the second one. Defaults to `true`
    /// for the callers that only ever build a list when it is showing.
    var isShowing: Bool = true

    /// This list's own answer to "show completed", when the user has given one.
    ///
    /// `nil` means the Settings preference stands. Held per *destination* —
    /// cleared below when the list changes — so flipping the toggle in Today
    /// says nothing about what Anytime should show.
    @State private var showResolvedOverride: Bool?

    /// The same, for overdue work. See `AppSettings.showOverdue`.
    @State private var showOverdueOverride: Bool?

    private var includeResolved: Bool {
        showResolvedOverride ?? settings.showResolved
    }

    private var includeOverdue: Bool {
        showOverdueOverride ?? settings.showOverdue
    }

    var body: some View {
        #if DEBUG && DEBUG_UI
        Self._printChanges()
        #endif
        return DestinationTodoList(
            destination: destination,
            includeResolved: includeResolved,
            includeOverdue: includeOverdue,
            showResolvedOverride: $showResolvedOverride,
            showOverdueOverride: $showOverdueOverride,
            selectedTodo: $selectedTodo,
            createRequest: createRequest,
            capturedTodo: capturedTodo,
            windowID: windowID,
            isShowing: isShowing
        )
        .id(QueryIdentity(
            destination: destination,
            includeResolved: includeResolved,
            includeOverdue: includeOverdue,
            weekStart: WeekMath.startOfWeek(
                containing: Date(), calendar: settings.calendar
            )
        ))
        // A per-list override belongs to the list it was set on; the next one
        // starts from the user's preference again.
        .onChange(of: destination) { _, _ in
            showResolvedOverride = nil
            showOverdueOverride = nil
        }
    }

    /// What the row query is built from. A change to any of these rebuilds it.
    private struct QueryIdentity: Hashable {
        let destination: ListDestination
        let includeResolved: Bool
        let includeOverdue: Bool

        /// The current week, so the query is rebuilt when the week turns over.
        ///
        /// The other lists survive without this because their predicates are
        /// *ranges* — "dated before the end of today" stays broadly right as
        /// the clock moves, and a stale bound shows slightly wrong rows rather
        /// than none. The week lists compare `weekAnchor` for **equality**
        /// against an anchor computed from the `now` passed in at construction,
        /// and a `@Query`'s descriptor is fixed once built. So a view built
        /// before the boundary goes on asking for the *previous* week's anchor,
        /// which no row carries any more, and the list renders empty — the bug
        /// this field exists to prevent.
        ///
        /// Day-granular and derived from the week, not from `Date()` itself: it
        /// has to change exactly once per week, or every redraw would get a new
        /// identity and tear the whole list down.
        let weekStart: Date
    }
}

private struct DestinationTodoList: View {
    let destination: ListDestination

    /// Whether finished work is in the query, and the per-list switch that can
    /// change it. See `TodoListView.showResolvedOverride`.
    let includeResolved: Bool
    @Binding var showResolvedOverride: Bool?

    /// The same, for work dated before today.
    let includeOverdue: Bool
    @Binding var showOverdueOverride: Bool?

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

    /// The window this list is in; see `TodoListView.windowID`.
    var windowID: UUID?

    /// Whether this list is on screen; see `TodoListView.isShowing`.
    var isShowing: Bool = true

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
        includeOverdue: Bool = true,
        showResolvedOverride: Binding<Bool?> = .constant(nil),
        showOverdueOverride: Binding<Bool?> = .constant(nil),
        selectedTodo: Binding<Todo?>,
        createRequest: Binding<Int>? = nil,
        capturedTodo: Binding<UUID?>? = nil,
        windowID: UUID? = nil,
        isShowing: Bool = true
    ) {
        self.destination = destination
        self.includeResolved = includeResolved
        self.includeOverdue = includeOverdue
        self._showResolvedOverride = showResolvedOverride
        self._showOverdueOverride = showOverdueOverride
        self._selectedTodo = selectedTodo
        self.createRequest = createRequest
        self.capturedTodo = capturedTodo
        self.windowID = windowID
        self.isShowing = isShowing

        _destinationTodos = Query(
            TodoQueries.descriptor(
                for: destination,
                calendar: AppSettings.shared.calendar,
                includeResolved: includeResolved,
                includeOverdue: includeOverdue
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
    /// The to-do whose recurrence panel is open, from the row's schedule chip
    /// or the context menu.
    @State private var repeatingTodo: Todo?

    /// Where the arrow keys are pointing.
    ///
    /// Separate from `focusedTodoID`, which is text-field focus: a row can be
    /// keyboard-selected without the caret being in its title, and that
    /// distinction is what lets Cmd+K toggle a row rather than typing into it.
    @State private var cursor = KeyboardCursor()

    /// The rows picked out to act on together, if any.
    ///
    /// A third notion of "current row" beside the cursor and the caret, and
    /// deliberately so: the cursor is *one* row the user is reading, while this
    /// is a set they have gathered up to act on. Empty almost all the time —
    /// see `TodoMultiSelection.isActive` for when the bar appears.
    @State private var multiSelection = TodoMultiSelection()
    /// Set while the bulk scheduling panel is open.
    @State private var isSchedulingSelection = false
    /// Set while the bulk "move to" picker is open.
    @State private var isMovingSelection = false
    /// Set while confirming a bulk delete.
    @State private var isConfirmingBulkDelete = false
    /// The last row order the cursor was reconciled against, so a row vanishing
    /// can be resolved to its nearest surviving neighbour.
    @State private var lastRowOrder: [UUID] = []

    /// What the user has typed into the pull-down search field, if anything.
    @State private var searchText = ""

    /// Set while this list's calendar is pushed on top of it.
    @State private var calendarRoute: CalendarRoute?

    /// The to-do the pushed calendar is editing.
    ///
    /// Separate from `selectedTodo` because the two are presented differently:
    /// a row picked in this list pushes a page, while a block picked on the
    /// calendar opens a sheet over it. See `todoDetailSheet(selection:)` for
    /// why the calendar cannot push — a second navigation destination for
    /// `Todo` in one stack presents from the root and drops the calendar.
    @State private var calendarSelectedTodo: Todo?

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

    /// Split into the groups below rather than written as one chain.
    ///
    /// The modifiers this view needs are numerous enough that the whole chain
    /// as a single expression stopped type-checking in reasonable time — the
    /// compiler gave up on it outright. Each group is now its own function, so
    /// several small expressions are solved instead of one large one.
    ///
    /// Only the grouping is new: the modifiers keep the order they had, since
    /// each group wraps the one before it exactly as the chain did. Read the
    /// `.modifiedBy` calls top to bottom and the order is the original one.
    var body: some View {
        #if DEBUG && DEBUG_UI
        Self._printChanges()
        #endif
        // Resolved *once* per redraw, here at the top, and handed to everything
        // below that needs it.
        //
        // `visibleTodos` runs the destination's whole query chain — a SwiftData
        // fetch plus the residual in-memory passes — and `visibleRowOrder` runs
        // that chain *and* walks `nestedSubtasks` for every row it returns.
        // Each was a computed property, so every reference re-ran the whole
        // thing: the list content read one, and two separate `onChange`
        // observers read the other, which put three full query chains and a
        // `nestedSubtasks` pass per row into every single body evaluation.
        // During a scroll, where SwiftUI evaluates the body continuously, that
        // is what made the pane hang.
        let rows = visibleTodos
        let order = rowOrder(of: rows)
        return droppableList(rows)
            .modifiedBy(creationHandling)
            .modifiedBy(lifecycle)
            .modifiedBy { keyboardHandling($0, order: order) }
            .modifiedBy(presentations)
            .modifiedBy { multiSelectHandling($0, rows: rows, order: order) }
    }

    /// Answering the app-wide create button and Cmd+N, and the pushed calendar.
    private func creationHandling(_ content: some View) -> some View {
        content
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
            .toolbar {toolbar}
            // Pushed rather than presented: it is the same list seen another way,
            // so Back returns to the rows it was opened from.
            .navigationDestination(item: $calendarRoute) { route in
                CalendarView(
                    selectedTodo: $calendarSelectedTodo,
                    destination: route.destination,
                    createRequest: createRequest,
                    onShowList: { calendarRoute = nil },
                    windowID: windowID,
                    // The list underneath this one stands down while it is
                    // pushed — see `isShowingList` — so the calendar takes over
                    // the screen's commands, but only while the tab holding
                    // both is itself the one on screen.
                    isShowing: isShowing
                )
                .todoDetailSheet(selection: $calendarSelectedTodo)
            }
            // Leaving the calendar takes its editor with it, so a sheet cannot
            // outlive the screen that raised it.
            .onChange(of: calendarRoute) { _, route in
                if route == nil { calendarSelectedTodo = nil }
            }
            // A calendar opened from one list has no meaning in the next.
            .onChange(of: destination) { _, _ in calendarRoute = nil }
    }

    /// Arrival and departure: what a list clears when it opens, closes, or is
    /// swapped for another.
    private func lifecycle(_ content: some View) -> some View {
        content
            // Visiting a list is what "viewing" means, so its dots clear on arrival.
            .task(id: destination) { markVisibleAsViewed() }
            // Switching lists drops focus, so the keyboard never follows the user
            // to a screen they did not open it on. The query goes with it: a search
            // typed in one list has no meaning in the next.
            .onChange(of: destination) { _, _ in
                focusedTodoID = nil
                searchText = ""
            }
            // Any panel raised from this list closes with it.
            //
            // The list is rebuilt from scratch whenever the destination or the
            // resolved preference changes — that is what `QueryIdentity` is for —
            // and a sheet still on screen when that happens is orphaned: its
            // presenter is gone, so the close button, the Escape key, and every
            // action inside it stop doing anything, and the only way out is to
            // quit the app.
            //
            // Reached most easily through the panels themselves, which is why it
            // matters: pausing a series refiles it from Today into Anytime, and a
            // user following it there with the panel open would strand it.
            .onDisappear {
                repeatingTodo = nil
                schedulingTodo = nil
                movingTodo = nil
            }
            .onChange(of: focusedTodoID) { previous, current in
                handleFocusChange(from: previous, to: current)
                // Typing in a row is also a way of choosing it, so the cursor
                // follows the caret. Without this, Cmd+K after clicking into a
                // title would act on whatever the arrows last pointed at.
                if let current { cursor.select(current) }
            }
    }

    /// Where the pane's own focus lives, and the keys it answers.
    private func keyboardHandling(_ content: some View, order: [UUID]) -> some View {
        content
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
            .keyboardCommands(
                isActive: isKeyboardTarget,
                isShowing: isShowingList,
                windowID: windowID
            ) { command in
                perform(command)
            }
            // Keeps the cursor on something real, and the selection free of
            // rows that have left, as the list changes underneath them.
            //
            // One observer for both rather than the two this used to be: each
            // `onChange(of:)` re-evaluated the row order independently, and
            // that order is the expensive value — a full query chain plus a
            // `nestedSubtasks` walk. They watch the same thing and are cheap to
            // run together.
            .onChange(of: order) { previous, current in
                cursor.reconcile(with: current, previousOrder: previous)
                lastRowOrder = current
                multiSelection.reconcile(with: current)
            }
            // A cursor from one list means nothing in the next.
            .onChange(of: destination) { _, _ in cursor.select(nil) }
    }

    /// The chips, sheets and dialogs raised from this list.
    private func presentations(_ content: some View) -> some View {
        content
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
                    Button(pending.confirmLabel) {
                        store.setStateCascading(pending.todo, to: pending.target)
                        pendingCascade = nil
                    }
                    if let alternate = pending.alternateSubtaskState {
                        Button(pending.alternateLabel) {
                            store.setStateCascading(
                                pending.todo,
                                to: pending.target,
                                subtaskState: alternate
                            )
                            pendingCascade = nil
                        }
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
                        // Through `schedule` rather than a bare `update`, so the
                        // move is undoable: this is the action that takes the row
                        // off the list the user is looking at.
                        store.schedule(todo, to: date, hasTime: hasTime)
                        schedulingTodo = nil
                    },
                    onPickWeek: { week in
                        // Same verb, same undo entry: the user is answering "when",
                        // and how precisely they answered does not change what a
                        // mistaken tap costs them.
                        store.schedule(todo, forWeek: week)
                        schedulingTodo = nil
                    },
                    onAddReminder: {
                        // The full reminder editor lives in the detail view.
                        schedulingTodo = nil
                        selectedTodo = todo
                    },
                    onDismiss: { schedulingTodo = nil },
                    onRepeat: {
                        // Handed over rather than stacked: two sheets deep on a
                        // phone leaves no room for the panel itself.
                        schedulingTodo = nil
                        DispatchQueue.main.async { repeatingTodo = todo }
                    },
                    acceptsTypedDate: schedulingFromKeyboard
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $repeatingTodo) { todo in
                RecurrencePickerView(
                    todo: todo,
                    onPick: { rule in
                        store.setRecurrence(rule, on: todo)
                        repeatingTodo = nil
                    },
                    onSetStatus: { status in
                        store.setRecurrenceStatus(status, on: todo)
                        repeatingTodo = nil
                    },
                    onDismiss: { repeatingTodo = nil }
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
            .multiSelectPanels(
                isScheduling: $isSchedulingSelection,
                isMoving: $isMovingSelection,
                isConfirmingDelete: $isConfirmingBulkDelete,
                deletePrompt: bulkDeletePrompt,
                // Cmd+S over a selection earns the typed-date field for the same
                // reason it does over one row: typing is why the panel opened.
                schedulingAcceptsTypedDate: schedulingFromKeyboard,
                onPickDate: { date, hasTime in
                    withAnimation(Theme.Animation.listChange) {
                        store.schedule(selectedTodos, to: date, hasTime: hasTime)
                    }
                },
                onPickWeek: { week in
                    withAnimation(Theme.Animation.listChange) {
                        store.schedule(selectedTodos, forWeek: week)
                    }
                },
                onPickDestination: { destination in
                    withAnimation(Theme.Animation.listChange) {
                        apply(destination, to: selectedTodos)
                    }
                },
                onConfirmDelete: performBulkDelete
            )
    }

    /// Keeping the selection, its bar, and the shell in step.
    private func multiSelectHandling(_ content: some View, rows: [Todo], order: [UUID]) -> some View {
        content
            // A selection assembled in one list means nothing in the next, and the
            // bar would otherwise sit over rows it was never about.
            .onChange(of: destination) { _, _ in multiSelection.clear() }
            // Tell the shell, so the floating create button gets out of the bar's
            // corner. See `MultiSelectPresence`.
            .onChange(of: multiSelection.isActive) { _, active in
                MultiSelectPresence.shared.setActive(active)
            }
            // A list left with a selection still up — switching tabs, or the pane
            // being torn down — must not leave the button hidden behind it.
            .onDisappear { MultiSelectPresence.shared.setActive(false) }
            // Escape leaves the mode, the same key that closes every other
            // transient thing in the app. Only claimed while there is a selection
            // to drop, so it still reaches whatever else wants it otherwise.
            .onKeyPress(.escape) {
                guard multiSelection.isActive else { return .ignored }
                endMultiSelect()
                return .handled
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The way in on a phone, where there are no modifier keys to
                    // say "and this one too". Toggles, so the same control is also
                    // the way back out.
                    Button {
                        withAnimation(Theme.Animation.quick) {
                            if multiSelection.isActive {
                                multiSelection.clear()
                            } else {
                                focusedTodoID = nil
                                multiSelection.beginExplicit()
                            }
                        }
                    } label: {
                        Label(
                            multiSelection.isActive ? "Done" : "Select",
                            systemImage: multiSelection.isActive
                                ? "checkmark.circle.fill"
                                : "checklist"
                        )
                    }
                    .help("Select several to-dos to act on together")
                }
            }
            #endif
    }

    /// The pane accepts drops too, so a to-do can be dragged from the Inbox
    /// panel onto whatever list is open without aiming at its sidebar row.
    ///
    /// Attached to the whole pane rather than to the rows: dropping *between*
    /// two rows is the same intent as dropping on the list, and a target that
    /// only covered the rows would leave the empty space below them dead.
    private func droppableList(_ rows: [Todo]) -> some View {
        searchableList(rows)
            // No drop indicator line, and so no hover tracking to feed one.
            //
            // Drawing it needed a second `DropDelegate` layered over this
            // pane's `dropDestination`, purely to follow the pointer. On macOS
            // that delegate competes for the drag: whichever way it answered
            // `validateDrop`, a drag that crossed this list stopped reaching
            // the sidebar, so a to-do could no longer be dragged from a list
            // onto a project or space — the app's main way of filing work.
            // Reordering by dragging is a convenience; moving a to-do between
            // projects is not, and one cost the other.
            //
            // `TodoDropIndicator` and its tests are left in place: the
            // arithmetic is correct and worth keeping for a future attempt
            // that can track the pointer without a competing drop target.
            .todoDropTarget(destination, store: store)
            // The bar goes over the whole pane, so it stays put while the list
            // scrolls underneath it.
            .multiSelectBar(isPresented: multiSelection.isActive) { multiSelectBar(rows: rows) }
    }

    /// The list, plus its search field.
    ///
    /// `searchable` is attached here rather than to the `ZStack` in `body`: the
    /// floating create button is the ZStack's other child, and hanging the
    /// field off the stack leaves the revealed search bar unable to take focus.
    /// Bound to the scroll view directly it behaves normally, and the
    /// pull-down gesture has the right scroll view to attach to.
    private func searchableList(_ rows: [Todo]) -> some View {
        listContent(rows)
            // Hidden by default and revealed by pulling the list down, so the
            // field costs nothing until it is wanted.
            .pullDownSearchable(
                text: $searchText,
                prompt: searchPrompt,
                isFocused: $isSearchFocused
            )
    }

    private func listContent(_ visibleTodos: [Todo]) -> some View {
        rows(visibleTodos)
    }

    #if os(macOS)
    private let rowInsets = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
    #else
    private let rowInsets = EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
    #endif
    
    @ViewBuilder
    private func rows(_ visibleTodos: [Todo]) -> some View {
        if visibleTodos.isEmpty && isSearching {
            SearchEmptyState(query: searchText, scopeDescription: searchScopeDescription)
        } else if visibleTodos.isEmpty && !showsPendingReminders {
            // The project's own dates still belong on screen when it has no
            // to-dos yet: an empty project with a deadline is exactly the case
            // where the deadline is worth seeing.
            VStack(spacing: 0) {
                projectMetadataHeader
                    .padding(.horizontal)
                emptyState
            }
        } else {
            List {
                // What the project itself is scheduled for, above the work it
                // holds. Shown only for a project — the cross-cutting lists are
                // date rules rather than things with dates of their own.
                if datedProject != nil {
                    projectMetadataHeader
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                }

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
                            isMultiSelected: multiSelection.contains(todo.uuid),
                            onToggle: { _ in handleToggle(todo) },
                            onSelectState: { handleSetState(todo, to: $0) },
                            onTitleChange: { handleTitleChange($0, for: todo) },
                            onNotesChange: { _ in store.save() },
                            menu: { AnyView(rowMenu(for: todo)) },
                            onSubmitTitle: { createTodoAfterSubmit(from: todo) },
                            onShowDetail: { _ in showDetail(for: todo) },
                            onEditRecurrence: { openRecurrence(for: $0) },
                            focusedTodoID: $focusedTodoID
                        )
                        // The tap that expands a row is attached here rather
                        // than inside the row, which captures no taps of its
                        // own: only the list knows that expanding is also a
                        // cursor move, and only it can leave the already
                        // expanded row alone so a second tap reaches the title
                        // field instead of being swallowed.
                        .contentShape(Rectangle())
                        .todoSelectionGesture(
                            isSelecting: multiSelection.isActive,
                            onPlainTap: { handleRowTap(todo) },
                            onToggle: { toggleSelection(of: todo) },
                            onExtend: { extendSelection(to: todo) }
                        )
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
                                isMultiSelected: multiSelection.contains(subtask.uuid),
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
                                onEditRecurrence: { openRecurrence(for: $0) },
                                focusedTodoID: $focusedTodoID
                            )
                            .padding(.leading, 28)
                            .contentShape(Rectangle())
                            .todoSelectionGesture(
                                isSelecting: multiSelection.isActive,
                                onPlainTap: { handleRowTap(subtask) },
                                onToggle: { toggleSelection(of: subtask) },
                                onExtend: { extendSelection(to: subtask) }
                            )
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
                // No `onMove`. It is SwiftUI's own reordering gesture, and on
                // macOS it claims the drag as soon as the pointer moves inside
                // the list — drawing the insertion line and keeping the session
                // for itself. A drag that started in the list could then never
                // reach the sidebar, so a to-do could not be filed into a
                // project or space, which is the more valuable of the two.
                //
                // The rows stay draggable through `todoDraggable`, and every
                // destination accepts them through `todoDropTarget`.
                
                Spacer()
                    .frame(width: 50, height: 400)

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
            .contentMargins(.top, 10, for: .scrollContent)
            // Swiping down over the list dismisses the keyboard raised by
            // inline title editing.
            .scrollDismissesKeyboard(.interactively)
            .animation(Theme.Animation.listChange, value: visibleTodos.map(\.uuid))
            // The coordinate space these are measured against is declared in
            // `droppableList`, alongside the drop target that reports the
            // pointer, so both sides share an origin.
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
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: Binding(
                get: { includeResolved },
                set: { showResolvedOverride = $0 }
            )) {
                Label(
                    includeResolved ? "Hide Completed" : "Show Completed",
                    systemImage: includeResolved ? "eye.slash" : "eye"
                )
            }
            .help(
                includeResolved
                ? "Hide completed items in this list"
                : "Show completed items in this list"
            )
        }
        // Only the lists that reach backwards in time can hide anything,
        // so the switch is offered only there. On Anytime or a project it
        // would be a control that visibly does nothing.
        if showsOverdueToggle {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: Binding(
                    get: { includeOverdue },
                    set: { showOverdueOverride = $0 }
                )) {
                    Label(
                        includeOverdue ? "Hide Overdue" : "Show Overdue",
                        systemImage: includeOverdue
                        ? "calendar.badge.minus"
                        : "calendar.badge.exclamationmark"
                    )
                }
                .help(
                    includeOverdue
                    ? "Hide work dated before today"
                    : "Show work dated before today"
                )
            }
        }
        // A project's own title, dates and place are edited on its detail
        // page. Reaching it from here matters because the sidebar row and
        // this list both navigate to the project's *contents*: without
        // this, the only way to change a project was to find it as a row in
        // some other list.
        if let project = currentProject {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showDetail(for: project)
                } label: {
                    Label("Edit Project…", systemImage: "slider.horizontal.3")
                }
                .help("Edit this project's title, dates, and place")
                // The project is not one of the rows below, so no row can
                // anchor its popover on macOS. The button that opens it
                // does instead; on iOS this is a no-op and the detail page
                // is pushed as usual.
                .todoDetailPopover(for: project, selection: $selectedTodo)
            }
        }
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
            assignedDate: defaultAssignedDate,
            weekSchedule: defaultWeekSchedule
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

    /// Raise the recurrence panel, dropping focus so the keyboard does not sit
    /// over it.
    private func openRecurrence(for todo: Todo) {
        focusedTodoID = nil
        repeatingTodo = todo
    }

    /// A tap on a row, in either of the two stages it can be.
    ///
    /// The first tap on an unselected row selects it; a tap on the row that is
    /// already selected opens the detail. That second stage used to be missing
    /// — the handler returned early on the selected row — so the only way into
    /// the detail was the chevron, and tapping a to-do appeared to do nothing.
    ///
    /// A tap that lands on the title field never arrives here: the field is an
    /// inner control and takes its own taps, so typing in an expanded row is
    /// unaffected by this. Only taps that missed every control reach the row.
    private func handleRowTap(_ todo: Todo) {
        if cursor.selection == todo.uuid {
            showDetail(for: todo)
        } else {
            withAnimation(Theme.Animation.rowExpand) { selectRow(todo) }
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
        // A multi-selection survives scrolling. It is a set the user assembled
        // deliberately and is about to act on, and losing it on the scroll that
        // reaches the row they were heading for would make selecting anything
        // past one screenful impossible.
        guard !multiSelection.isActive else { return }
        guard cursor.selection != nil || focusedTodoID != nil else { return }
        focusedTodoID = nil
        withAnimation(Theme.Animation.rowExpand) { cursor.select(nil) }
    }

    // MARK: Multiple selection

    /// Add or remove one row — Cmd-click, or a tap in iOS's Select mode.
    private func toggleSelection(of todo: Todo) {
        // Text focus and multi-selection are incompatible: the caret is in one
        // row, and this is about several.
        focusedTodoID = nil
        withAnimation(Theme.Animation.quick) {
            multiSelection.apply(.toggle, to: todo.uuid, in: visibleRowOrder)
        }
        isListFocused = true
    }

    /// Shift-click: select from the anchor to this row.
    private func extendSelection(to todo: Todo) {
        focusedTodoID = nil
        withAnimation(Theme.Animation.quick) {
            // A shift-click with nothing selected yet has no anchor of its own,
            // so the row the user was already reading becomes one. Without
            // this, the first Shift-click after arrowing down a list selects a
            // single row instead of the range the user was pointing at.
            if multiSelection.ids.isEmpty, let cursorID = cursor.selection {
                multiSelection.apply(.replace, to: cursorID, in: visibleRowOrder)
            }
            multiSelection.apply(.extend, to: todo.uuid, in: visibleRowOrder)
        }
        isListFocused = true
    }

    /// Leave multi-select: the Done button, and Escape on a Mac.
    private func endMultiSelect() {
        withAnimation(Theme.Animation.quick) { multiSelection.clear() }
    }

    /// The selected to-dos, in the order they are drawn.
    ///
    /// Ordered rather than handed over as a set, so that actions which care
    /// about order — duplicating, which inserts each copy after its original —
    /// produce a result that matches what the user was looking at.
    private var selectedTodos: [Todo] {
        // The guard first, so nothing selected costs nothing: `visibleTodos` is
        // a whole query chain, and as an argument it would be evaluated before
        // the callee could decline to use it.
        guard multiSelection.count > 0 else { return [] }
        return selectedTodos(in: visibleTodos)
    }

    /// The same, over rows the caller has already resolved.
    private func selectedTodos(in rows: [Todo]) -> [Todo] {
        guard multiSelection.count > 0 else { return [] }
        var byID: [UUID: Todo] = [:]
        for todo in rows {
            byID[todo.uuid] = todo
            for subtask in nestedSubtasks(of: todo) {
                byID[subtask.uuid] = subtask
            }
        }
        return rowOrder(of: rows).compactMap { id in
            multiSelection.contains(id) ? byID[id] : nil
        }
    }

    /// The bar along the bottom, wired to the bulk verbs.
    private func multiSelectBar(rows: [Todo]) -> MultiSelectBar {
        let selected = selectedTodos(in: rows)
        return MultiSelectBar(
            count: selected.count,
            allResolved: !selected.isEmpty && selected.allSatisfy { $0.state.isResolved },
            allProjects: !selected.isEmpty && selected.allSatisfy(\.isProject),
            spaces: spaces,
            onToggleAll: {
                withAnimation(Theme.Animation.listChange) { store.toggleAll(selected) }
            },
            onSetState: { state in
                withAnimation(Theme.Animation.listChange) { store.setState(selected, to: state) }
            },
            onSchedule: {
                focusedTodoID = nil
                // A tap on When is not the keyboard route in, so the panel opens
                // without the typed-date field even if Cmd+S opened it earlier.
                schedulingFromKeyboard = false
                isSchedulingSelection = true
            },
            onMove: {
                focusedTodoID = nil
                isMovingSelection = true
            },
            onMoveToSpace: { space in
                withAnimation(Theme.Animation.listChange) { store.move(selected, toSpace: space) }
            },
            onDuplicate: duplicateSelection,
            onSetIsProject: { promoted in
                withAnimation(Theme.Animation.listChange) {
                    store.setIsProject(selected, promoted)
                }
            },
            onDelete: { requestBulkDelete() },
            onSelectAll: {
                withAnimation(Theme.Animation.quick) {
                    multiSelection.selectAll(in: visibleRowOrder)
                }
            },
            onDone: endMultiSelect
        )
    }

    /// Delete the selection, asking first when it takes more with it.
    ///
    /// The same rule as the single-row delete: rows with nothing attached go
    /// straight away, since retyping one is cheaper than a dialog. A selection
    /// that would take subtasks down with it is worth a question, because the
    /// count of what actually goes is not visible from the rows.
    private func requestBulkDelete() {
        let selected = selectedTodos
        guard !selected.isEmpty else { return }

        if selected.allSatisfy({ $0.subtaskList.isEmpty }) {
            performBulkDelete()
        } else {
            isConfirmingBulkDelete = true
        }
    }

    private func performBulkDelete() {
        let selected = selectedTodos
        focusedTodoID = nil
        withAnimation(Theme.Animation.listChange) {
            store.delete(selected)
            multiSelection.clear()
        }
    }

    /// Names what a bulk delete would take, including the subtasks that go
    /// with it — the part the rows on screen do not show.
    private var bulkDeletePrompt: String {
        let selected = selectedTodos
        let extra = selected.reduce(0) { $0 + $1.descendants.count }
        let rows = selected.count == 1 ? "1 to-do" : "\(selected.count) to-dos"
        guard extra > 0 else {
            return "Delete \(rows)? This cannot be undone."
        }
        let noun = extra == 1 ? "subtask" : "subtasks"
        return "Deleting \(rows) also deletes \(extra) \(noun). This cannot be undone."
    }

    /// Every row the arrow keys can land on, parents and their nested subtasks
    /// in the order they are drawn.
    ///
    /// Built from the same composition the list renders, so the cursor walks
    /// exactly what is on screen — including a subtask nested under its parent,
    /// which is a row the user can see and therefore expects to reach.
    private var visibleRowOrder: [UUID] {
        rowOrder(of: visibleTodos)
    }

    /// The same, over rows that have already been resolved.
    ///
    /// The body computes the row list once and derives the order from *that*
    /// array rather than re-running the query chain — see the note in `body`.
    /// The property above stays for the event handlers, which run on a
    /// keystroke or a click rather than per frame and have no resolved list to
    /// hand: recomputing there costs one chain on an actual user action.
    private func rowOrder(of rows: [Todo]) -> [UUID] {
        rows.flatMap { [$0.uuid] + nestedSubtasks(of: $0).map(\.uuid) }
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
        guard isShowingList else { return false }
        // A multi-selection counts on its own: rows picked with Cmd+A or a
        // shift-click leave the cursor where it was — possibly nowhere — and
        // without this a list showing "21 selected" answered no shortcut at all.
        return hasSelection || cursor.selection != nil || focusedTodoID != nil || selectedTodo != nil
    }

    /// Whether this list is the surface the user is on.
    ///
    /// What the commands that act on the screen rather than on a row are gated
    /// on — Cmd+N, Cmd+F — which is why it does not ask for a selection: those
    /// are pressed most often on a list just opened, before anything is
    /// selected. The two conditions are the same ones `isKeyboardTarget` needs
    /// before it can even ask about the cursor: this list's tab has to be the
    /// one showing, and its pushed calendar — which answers the same commands
    /// — must not be on top of it.
    private var isShowingList: Bool {
        isShowing && !isShowingCalendar
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

    /// Run a keyboard command against the selection, or the cursor's row.
    ///
    /// Every verb that can mean "all of these" takes the bulk path whenever a
    /// multi-selection is up: a shortcut that acted on one row while the bar
    /// along the bottom reported nine selected would be acting on a row the user
    /// had stopped thinking about, and silently — nothing on screen says which
    /// of the nine it picked. The bulk paths are the same ones that bar's own
    /// buttons use, so Cmd+S and When do the same thing to the same rows.
    ///
    /// Cmd+Return is the exception, below: a detail view shows one to-do.
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
            if hasSelection {
                focusedTodoID = nil
                schedulingFromKeyboard = true
                isSchedulingSelection = true
                return
            }
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            schedulingFromKeyboard = true
            schedulingTodo = todo

        case .toggleDone:
            if hasSelection {
                let selected = selectedTodos
                withAnimation(Theme.Animation.listChange) { store.toggleAll(selected) }
                return
            }
            guard let todo = commandTarget else { return }
            handleToggle(todo)

        // Alone among these in having no bulk form: the detail view shows one
        // to-do, so with a selection up this keeps acting on the cursor's row
        // rather than picking one of many to open.
        case .showDetail:
            guard let todo = commandTarget else { return }
            showDetail(for: todo)

        case .move:
            if hasSelection {
                focusedTodoID = nil
                isMovingSelection = true
                return
            }
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            movingTodo = todo

        case .duplicate:
            if hasSelection {
                duplicateSelection()
                return
            }
            guard let todo = commandTarget else { return }
            duplicate(todo)

        case .delete:
            if hasSelection {
                focusedTodoID = nil
                requestBulkDelete()
                return
            }
            guard let todo = commandTarget else { return }
            focusedTodoID = nil
            requestDelete(todo)

        case .selectAll:
            selectAllRows()
        }
    }

    /// Whether a keyboard command should act on the selection rather than a row.
    ///
    /// Asks for actual rows rather than `multiSelection.isActive`, which is also
    /// true in iOS's explicit mode with nothing picked yet. That state means
    /// "I am about to choose", and a Cmd+S there should still reach the cursor's
    /// row rather than opening a picker over an empty batch.
    private var hasSelection: Bool { multiSelection.count > 0 }

    /// Copy every selected row, leaving the copies selected.
    ///
    /// The same rule the single-row duplicate follows with the cursor, and the
    /// one the action bar's own Duplicate uses: the copies are what the user is
    /// about to edit.
    private func duplicateSelection() {
        let copies = store.duplicate(selectedTodos)
        withAnimation(Theme.Animation.listChange) {
            multiSelection.selectAll(in: copies.map(\.uuid))
        }
    }

    /// Put every row on screen into the selection.
    ///
    /// "On screen" is the whole of it: the rows the current filter and search
    /// leave showing, subtasks included, which is the same order a shift-click
    /// ranges over. Selecting rows a filter is hiding would hand the action bar
    /// a count the user cannot account for.
    private func selectAllRows() {
        let order = visibleRowOrder
        guard !order.isEmpty else { return }
        // The caret has to leave the row it is in: the selection is about whole
        // to-dos, and a title still taking keystrokes underneath a bar offering
        // to delete nine of them is the wrong thing to leave on screen.
        focusedTodoID = nil
        withAnimation(Theme.Animation.quick) {
            multiSelection.selectAll(in: order)
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

    /// Apply a picked move destination to a whole selection.
    ///
    /// The same three cases as the single-row version, through the bulk verbs
    /// so the move is one undo entry rather than one per row.
    private func apply(_ destination: MoveDestinationView.Destination, to todos: [Todo]) {
        switch destination {
        case .none:
            store.move(todos, toParent: nil)
            store.move(todos, toSpace: nil)
        case .space(let id):
            store.move(todos, toParent: nil)
            store.move(todos, toSpace: spaces.first { $0.uuid == id })
        case .project(let id):
            guard let project = TodoQueries.todo(uuid: id, in: context) else { return }
            store.move(todos, toParent: project)
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

        Divider()

        Button {
            openRecurrence(for: todo)
        } label: {
            Label(
                todo.isRecurring ? "Edit Repeat…" : "Repeat…",
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )
        }

        // Only an instance can be skipped: skipping means "this occurrence did
        // not happen, move the series on", which has no meaning for a to-do
        // that is not one of a series.
        if todo.isRecurrenceInstance {
            Button {
                withAnimation(Theme.Animation.listChange) {
                    store.skipRecurrenceInstance(todo)
                }
            } label: {
                Label("Skip This One", systemImage: "forward.end")
            }
        }

        if todo.isRecurring {
            let status = todo.effectiveRecurrenceRule?.status ?? .active
            Button {
                store.setRecurrenceStatus(status == .active ? .paused : .active, on: todo)
            } label: {
                Label(
                    status == .active ? "Pause Repeat" : "Resume Repeat",
                    systemImage: status == .active ? "pause.circle" : "play.circle"
                )
            }
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

    /// Held as its own typed property rather than written inline in the
    /// dialog: `body` is already at the type-checker's limit, and an optional
    /// chain in a `String` position there is enough to push it over.
    private var cascadePrompt: String {
        pendingCascade?.prompt ?? ""
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

    /// The project this list is showing, if it is showing one.
    private var currentProject: Todo? {
        guard case .project(let id) = destination else { return nil }
        return TodoQueries.todo(uuid: id, in: context)
    }

    /// The project whose dates are worth a header, if there is one.
    ///
    /// `nil` for every other destination: the cross-cutting lists are date
    /// *rules*, so there is nothing of their own to show, and a space's dates
    /// live on the space editor rather than on its to-dos. Also nil for a
    /// project with no dates at all, which would give an empty strip.
    private var datedProject: Todo? {
        guard let project = currentProject,
              project.assignedDate != nil || project.dueDate != nil
        else { return nil }
        return project
    }

    /// The project's own dates, drawn above the work it holds.
    @ViewBuilder
    private var projectMetadataHeader: some View {
        if let project = datedProject {
            ProjectMetadataHeader(project: project) { showDetail(for: project) }
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

    /// Only the lists whose window reaches back past today can hold overdue
    /// work, so only they offer the switch.
    ///
    /// Tomorrow deliberately does not: it has no backward reach by design —
    /// late work belongs in Today, where it cannot be missed — so there is
    /// nothing for the toggle to hide. The undated lists have no window at all.
    private var showsOverdueToggle: Bool {
        switch destination {
        case .today, .thisWeek: true
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
        case .today, .tomorrow, .thisWeek, .nextWeek, .anytime, .logbook: true
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
        // The list is date-driven, so something created there should land in it
        // rather than dropping into the Inbox.
        case .today:
            Calendar.current.startOfDay(for: Date())
        // Same rule one day on: something added to Tomorrow has to land there
        // rather than in Today, or the row vanishes the moment it is created.
        case .tomorrow:
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
        // Anytime means scheduled-but-undated, which the bucket rules give a
        // to-do once it has a home; a date would move it into Today. The week
        // lists take `defaultWeekSchedule` instead — see below.
        default:
            nil
        }
    }

    /// The week lists place what is created in them into that week itself.
    ///
    /// The same rule `defaultAssignedDate` follows, expressed in the field the
    /// list actually filters on. This Week used to date new rows to *today*,
    /// which was the only way to land them in the list before the week fields
    /// existed — and it put them in Today as well, committing the user to a day
    /// they had not picked. Now the list can say what it means.
    private var defaultWeekSchedule: WeekSchedule? {
        switch destination {
        case .thisWeek: .thisWeek
        case .nextWeek: .nextWeek
        default: nil
        }
    }

    private var emptyTitle: String {
        switch destination {
        case .inbox: "Inbox Zero"
        case .today: "Nothing Today"
        case .tomorrow: "Nothing Tomorrow"
        case .thisWeek: "Nothing This Week"
        case .nextWeek: "Nothing Next Week"
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
        case .nextWeek: "Plan ahead — to-dos you schedule for next week collect here."
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


extension View {
    /// Apply one group of modifiers, written as a function taking a view.
    ///
    /// Only so that a long chain split into groups still reads in the order it
    /// runs: `a.modifiedBy(f).modifiedBy(g)` says what `g(f(a))` says, without
    /// asking the reader to unwrap it from the inside out. See
    /// `DestinationTodoList.body` for why that chain is split at all.
    fileprivate func modifiedBy<Result: View>(
        _ group: (Self) -> Result
    ) -> Result {
        group(self)
    }
}


