import SwiftUI
import SwiftData

/// Day or week calendar.
///
/// Scheduled todos without a time sit in a header row; timed todos are laid out
/// against the hour grid like calendar events, using their duration or the
/// configured default.
/// The calendar, wrapped so its row query can follow the visible dates.
///
/// A `@Query`'s predicate is fixed when the view is initialized, and the grid's
/// range is not: the user pages through days and weeks, and the scale switch
/// changes how much is on screen at once. This wrapper owns the anchor and
/// scale — either the caller's bindings or its own state — and gives the inner
/// view an identity built from the resulting date range, so paging rebuilds the
/// query against the new range rather than leaving it fetching the old one.
///
/// Fetching a range rather than a day: the week scale draws seven at once, and
/// one query for the span beats seven for the columns.
struct CalendarView: View {
    enum Scale: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var label: String { self == .day ? "Day" : "Week" }
    }

    @Binding var selectedTodo: Todo?
    var destination: ListDestination = .today
    var anchorDate: Binding<Date>?
    var scaleBinding: Binding<Scale>?
    var createRequest: Binding<Int>?
    var onShowList: (() -> Void)?

    /// The window this calendar is in, so a menu command aimed at another
    /// window is not answered here too. See `TodoListView.windowID`.
    var windowID: UUID?

    /// Whether this calendar is the screen the user is on; see
    /// `TodoListView.isShowing`. The calendar tab's view outlives a switch away
    /// from it, so Cmd+N would otherwise be answered by a grid nobody can see.
    var isShowing: Bool = true

    @Environment(AppSettings.self) private var settings

    /// Fallbacks for the callers that own neither value. Held here rather than
    /// in the inner view so the range can be computed before it is built.
    @State private var localScale: Scale = .day
    @State private var localAnchor = Date()

    /// Paging state, owned here rather than inside the view whose identity
    /// changes with the range.
    ///
    /// The inner view is recreated whenever the visible dates move, and a swipe
    /// *is* the visible dates moving — so `@State` down there would be reset by
    /// the very gesture that changes it, and the page would snap back under the
    /// user's finger. Held above the identity, it survives the rebuild.
    @State private var pageIndex = 0
    @State private var pageOrigin = Date()

    private var scale: Scale { scaleBinding?.wrappedValue ?? localScale }
    private var anchor: Date { anchorDate?.wrappedValue ?? localAnchor }

    /// The span the query covers: the visible page, plus one page either side.
    ///
    /// The neighbours are deliberate — paging is a swipe, and the next page is
    /// already partly on screen while it settles, so a range that stopped at
    /// the current page's edges would show a momentarily empty grid.
    private var fetchRange: (start: Date, end: Date) {
        let calendar = settings.calendar
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear

        let pageStart: Date
        switch scale {
        case .day:
            pageStart = calendar.startOfDay(for: anchor)
        case .week:
            pageStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
        }

        let start = calendar.date(byAdding: component, value: -1, to: pageStart) ?? pageStart
        let afterPage = calendar.date(byAdding: component, value: 2, to: pageStart) ?? pageStart
        return (start, afterPage)
    }

    var body: some View {
        let range = fetchRange
        return RangedCalendarView(
            selectedTodo: $selectedTodo,
            destination: destination,
            rangeStart: range.start,
            rangeEnd: range.end,
            anchorDate: anchorDate ?? $localAnchor,
            scaleBinding: scaleBinding ?? $localScale,
            pageIndex: $pageIndex,
            pageOrigin: $pageOrigin,
            createRequest: createRequest,
            onShowList: onShowList,
            windowID: windowID,
            isShowing: isShowing
        )
        .id(QueryIdentity(start: range.start, end: range.end))
    }

    /// What the row query is built from. Paging or switching scale moves the
    /// range, which rebuilds the query.
    private struct QueryIdentity: Hashable {
        let start: Date
        let end: Date
    }
}

private struct RangedCalendarView: View {
    typealias Scale = CalendarView.Scale

    @Binding var selectedTodo: Todo?

    /// The list the calendar was opened from.
    ///
    /// Determines both which to-dos are laid out and whether outside calendar
    /// events appear at all: from a space or project the calendar is about that
    /// container's work, so events from the user's calendars would be noise.
    var destination: ListDestination = .today

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings

    /// The dated, unresolved, Focus-visible work falling in the visible range.
    ///
    /// Narrowed by SQLite on both counts — which rows can be drawn at all, and
    /// which days are on screen — so paging to an empty week fetches nothing
    /// rather than reading the whole store and finding nothing in it. The
    /// per-day and per-container slicing left in the body is then comparison
    /// over the handful of rows a page can actually show.
    @Query private var datedTodos: [Todo]


    init(
        selectedTodo: Binding<Todo?>,
        destination: ListDestination,
        rangeStart: Date,
        rangeEnd: Date,
        anchorDate: Binding<Date>,
        scaleBinding: Binding<Scale>,
        pageIndex: Binding<Int>,
        pageOrigin: Binding<Date>,
        createRequest: Binding<Int>? = nil,
        onShowList: (() -> Void)? = nil,
        windowID: UUID? = nil,
        isShowing: Bool = true
    ) {
        self._selectedTodo = selectedTodo
        self.destination = destination
        self.anchorDate = anchorDate
        self.scaleBinding = scaleBinding
        self._pageIndex = pageIndex
        self._pageOrigin = pageOrigin
        self.createRequest = createRequest
        self.onShowList = onShowList
        self.windowID = windowID
        self.isShowing = isShowing

        _datedTodos = Query(
            TodoQueries.scheduledDescriptor(from: rangeStart, to: rangeEnd)
        )
    }

    /// Day or week, and the day being shown.
    ///
    /// Always bound here: the wrapper resolves the caller's bindings against
    /// its own fallback state before building this view, because the visible
    /// range has to be known in order to build the query.
    var anchorDate: Binding<Date>
    var scaleBinding: Binding<Scale>

    /// Incremented by the app-wide create button; the calendar answers by
    /// creating a block at the next quarter hour. See `createAtNextSlot`.
    var createRequest: Binding<Int>?

    /// See `CalendarView.windowID`.
    var windowID: UUID?

    /// See `CalendarView.isShowing`.
    var isShowing: Bool = true

    /// Called to go back to the list this calendar was opened from.
    ///
    /// Set only by the scoped calendars, which are one of two ways of reading
    /// the same list; the Calendar tab is a destination in its own right and
    /// has nothing to return to.
    var onShowList: (() -> Void)?

    @State private var eventStore = CalendarEventStore.shared

    /// The to-do being dragged to a new time, and how far it has moved.
    @State private var draggingTodoID: UUID?
    @State private var dragTranslation: CGFloat = 0
    /// Sideways travel, which on a week grid is what changes the day.
    ///
    /// Kept separate from the vertical translation because the two answer
    /// different questions — how many columns across, versus how many minutes
    /// down — and only the horizontal one is meaningless on a single-day grid.
    @State private var dragHorizontal: CGFloat = 0
    /// Which part of a block the current drag has hold of.
    @State private var dragMode: DragMode = .move
    /// Whether the block was already selected when the drag began.
    ///
    /// Selection changes as a drag starts — see `begin` — and the gesture is
    /// attached differently for a selected block. Remembering the value from
    /// the start keeps that attachment stable for the life of the gesture
    /// instead of swapping it out from under the finger.
    @State private var dragStartedSelected = false
    /// True for exactly as long as a block's drag recognizer is alive.
    ///
    /// Reset by SwiftUI on cancellation as well as on a normal end, unlike
    /// `onEnded`, which only runs when a gesture finishes cleanly. Watched
    /// below to clear the in-flight state a cancelled drag would otherwise
    /// leave behind.
    @GestureState private var isTracking = false
    /// A block sketched under the finger while a long press is held, before the
    /// to-do is actually created. Mirrors the placeholder Calendar.app shows.
    @State private var draft: DraftBlock?

    /// The block the user has tapped once.
    ///
    /// The calendar's tap is two-stage, like the list's: the first tap selects
    /// a block — which is what puts the checkbox, the chevron and the resize
    /// handles on it — and only the second opens the editor. `selectedTodo` is
    /// deliberately not used for this, because that binding *presents* the
    /// editor, so driving selection through it would collapse both stages into
    /// one tap.
    ///
    /// The keyboard cursor is the same idea by another route, so the two are
    /// kept in step rather than allowed to mark different blocks: whichever way
    /// a block was picked, it is the one wearing the controls.
    private var selectedBlockID: UUID? { cursor.selection }

    /// What a drag on a block is doing to it.
    ///
    /// Moving comes from a press anywhere on the block; the two resize modes
    /// come from the handles a selected block grows at its edges, which is how
    /// the stock Calendar distinguishes the two gestures as well.
    private enum DragMode: Equatable, CustomStringConvertible {
        case move
        case resizeStart
        case resizeEnd

        var description: String {
            switch self {
            case .move: "move"
            case .resizeStart: "resizeStart"
            case .resizeEnd: "resizeEnd"
            }
        }
    }
    /// Width of one day column, measured from the laid-out grid so overlapping
    /// blocks can be positioned as fractions of it.
    @State private var columnWidth: CGFloat = 0

    /// Height of one all-day chip, measured rather than assumed so the row's
    /// cap holds at every Dynamic Type size. See `chipHeightProbe`.
    @State private var chipHeight: CGFloat = AllDayMetrics.chipHeightEstimate

    /// A not-yet-created to-do being sketched by a long press.
    private struct DraftBlock: Equatable {
        let day: Date
        /// Start time, snapped to the grid.
        var start: Date
    }

    /// Where the arrow keys are pointing, over the blocks on the visible page.
    @State private var cursor = KeyboardCursor()
    /// Raised when completing a block is blocked by unfinished subtasks, so the
    /// calendar's checkbox asks the same question the list's does.
    @State private var pendingCascade: PendingCascade?
    /// The to-do whose scheduling panel is open, from Cmd+S.
    @State private var schedulingTodo: Todo?
    /// The to-do whose "move to" picker is open, from Cmd+M.
    @State private var movingTodo: Todo?

    /// Page currently shown, as an offset from `pageOrigin`, and the date page
    /// 0 refers to. Both owned by the wrapper — see its `pageIndex`.
    @Binding private var pageIndex: Int
    @Binding private var pageOrigin: Date

    /// How many pages exist either side of the origin. Large enough that
    /// recentring is invisible, small enough to stay cheap.
    private let pageWindow = 200

    private var pageRange: ClosedRange<Int> { -pageWindow...pageWindow }


    /// Height of one hour in the grid.
    private let hourHeight: CGFloat = 52

    private var calendar: Calendar { settings.calendar }
    private var store: TodoStore { TodoStore(context: context) }

    /// Whoever owns the value — the caller, or the wrapper's fallback state.
    private var scale: Scale {
        get { scaleBinding.wrappedValue }
        nonmutating set { scaleBinding.wrappedValue = newValue }
    }

    private var anchor: Date {
        get { anchorDate.wrappedValue }
        nonmutating set { anchorDate.wrappedValue = newValue }
    }

    /// Binding form, for the picker.
    private var scaleSelection: Binding<Scale> { scaleBinding }

    /// What the scoped calendar's switch selects between: the list it was
    /// opened from, or one of the grid's scales.
    private enum ViewMode: Hashable {
        case list
        case scale(Scale)
    }

    /// Reading gives whichever scale is showing; writing `.list` leaves the
    /// calendar instead of selecting anything.
    ///
    /// The selection deliberately never *becomes* `.list` — the segment acts as
    /// a button, so returning here and coming back finds the switch on the
    /// scale the user left, not stuck on a segment for a screen they are no
    /// longer looking at.
    private var viewModeSelection: Binding<ViewMode> {
        Binding(
            get: { .scale(scale) },
            set: { mode in
                switch mode {
                case .list: onShowList?()
                case .scale(let newScale): scale = newScale
                }
            }
        )
    }

    /// Outside calendar events belong on the cross-cutting lists only.
    ///
    /// Today and This Week are "what does my day look like" views, where the
    /// user's meetings are the point. A space or project calendar is scoped to
    /// that container, so events from elsewhere would be noise.
    private var showsCalendarEvents: Bool {
        switch destination {
        case .today, .tomorrow, .thisWeek, .anytime:
            settings.showCalendarEvents
        default:
            false
        }
    }

    /// One day's untimed rows, for the all-day header.
    ///
    /// Sliced out of `datedTodos` rather than queried per day: the fetch
    /// already covers the visible range and applied the state and Focus rules,
    /// so what is left is a date comparison and the container walk — and the
    /// week scale asks this seven times for one page.
    private func untimedOn(_ day: Date) -> [Todo] {
        TodoQueries.untimedOn(datedTodos, day: day, for: destination, calendar: calendar)
    }

    /// One day's timed rows, laid out against the hours. See `untimedOn`.
    private func timedOn(_ day: Date) -> [Todo] {
        TodoQueries.timedOn(datedTodos, day: day, for: destination, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pagedContent
        }
        // The week header appearing and the grid re-columning are one change,
        // so they move together rather than the header snapping in first.
        .animation(Theme.Animation.panel, value: scale)
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Reload whenever the visible range or the calendar preferences change.
        .task(id: eventReloadKey) { await reloadEvents() }
        // A cancelled drag never reaches `commitDrag`, so the block it was
        // moving would otherwise stay lifted — shadowed, half-opaque, and
        // offset — with nothing tracking the finger any more. `isTracking`
        // drops on cancellation too, which is what makes it a reliable place to
        // put the block back.
        //
        // This is only the cancellation path. A drag that ends normally has
        // already run `commitDrag` synchronously inside `onEnded` and cleared
        // `draggingTodoID`, so the guard below finds nothing to do and the
        // committed move is never second-guessed here.
        .onChange(of: isTracking) { _, tracking in
            guard !tracking, let dragged = draggingTodoID else { return }
            draggingTodoID = nil
            dragTranslation = 0
            dragHorizontal = 0
            dragMode = .move
            // Select here too. A cancelled drag never reaches `commitDrag`, so
            // without this the one path that does not select is the one where
            // the user grabbed a block and got nothing at all.
            cursor.select(dragged)
        }
        // The app-wide button asks; the calendar answers by blocking out the
        // next quarter hour on the day being shown.
        .onChange(of: createRequest?.wrappedValue) { _, _ in createAtNextSlot() }
        // Up and down act on the *selected block* rather than stepping between
        // blocks: on a grid the vertical axis is time, so the obvious thing for
        // an arrow key to do with something selected is move it through time.
        // Stepping between blocks is still available — with nothing selected
        // the same keys pick one, which is how the cursor gets started.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            arrowPressed(press)
        }
        .onKeyPress(.leftArrow) { shift(by: -1); return .handled }
        .onKeyPress(.rightArrow) { shift(by: 1); return .handled }
        .onKeyPress(.return) {
            guard let todo = cursorTodo else { return .ignored }
            selectedTodo = todo
            return .handled
        }
        .keyboardCommands(
            isActive: isShowing && (cursor.selection != nil || selectedTodo != nil),
            isShowing: isShowing,
            windowID: windowID
        ) { command in
            perform(command)
        }
        // Moving to another day drops a cursor that pointed at a block no
        // longer on screen.
        .onChange(of: anchor) { _, _ in cursor.select(nil) }
        .onChange(of: navigableTodoIDs) { previous, current in
            cursor.reconcile(with: current, previousOrder: previous)
        }
        .sheet(item: $schedulingTodo) { todo in
            SchedulePickerView(
                todo: todo,
                onPick: { date, hasTime in
                    // See the same call in `TodoListView`: scheduling is
                    // recorded so it can be undone.
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
                    schedulingTodo = nil
                    selectedTodo = todo
                },
                onDismiss: { schedulingTodo = nil },
                acceptsTypedDate: true
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
        // The block checkbox asks the same question the list's does when
        // unfinished subtasks stand in the way.
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
                Button("Keep Subtasks", role: .cancel) { pendingCascade = nil }
            }
        }
    }

    // MARK: Keyboard

    /// Every to-do the arrow keys can land on, in the order they read on the
    /// page: all-day items first, then timed blocks by start time.
    ///
    /// Scoped to the days actually on screen, so the cursor never selects
    /// something the user cannot see.
    private var navigableTodoIDs: [UUID] {
        let days = visibleDays

        return days.flatMap { day in
            // `timed` already comes back in start order, which is the order the
            // blocks are drawn down the column.
            untimedOn(day).map(\.uuid) + timedOn(day).map(\.uuid)
        }
    }

    private var cursorTodo: Todo? {
        guard let id = cursor.selection else { return nil }
        return TodoQueries.todo(uuid: id, in: context)
    }

    private func moveCursor(_ direction: KeyboardCursor.Direction) -> KeyPress.Result {
        var next = cursor
        guard next.move(direction, in: navigableTodoIDs) else { return .ignored }
        cursor = next
        return .handled
    }

    /// Route an up or down arrow, which does one of three things here.
    ///
    /// With a timed block selected the key edits it: plain and Shift move it
    /// through the day, Command changes how long it runs. With nothing selected
    /// — or with an all-day chip selected, which has no time to move — the key
    /// falls back to picking a block, so the arrows still get the cursor going.
    private func arrowPressed(_ press: KeyPress) -> KeyPress.Result {
        let direction: KeyboardCursor.Direction = press.key == .upArrow ? .up : .down
        // Up shortens and moves earlier; down lengthens and moves later. Both
        // read the same way on screen — the block follows the key.
        let sign = press.key == .upArrow ? -1 : 1

        // An untimed to-do sits in the all-day row and has no start to nudge,
        // so the keys keep their navigation meaning on it.
        guard let todo = cursorTodo, todo.assignedDate != nil, todo.assignedHasTime else {
            return moveCursor(direction)
        }

        let modifiers = press.modifiers
        let minutes = modifiers.contains(.shift)
            ? settings.calendarFineNudgeMinutes
            : settings.calendarNudgeMinutes

        if modifiers.contains(.command) {
            resize(todo, byMinutes: sign * minutes)
        } else {
            nudge(todo, byMinutes: sign * minutes)
        }
        return .handled
    }

    /// Move a block through its day by `minutes`, clamped to the day it is on.
    ///
    /// Clamped rather than allowed to roll into the next day: the grid shows
    /// one day (or one week of separate columns), so a block that slid past
    /// midnight would vanish from under the cursor that is still driving it.
    private func nudge(_ todo: Todo, byMinutes minutes: Int) {
        guard let current = todo.assignedDate,
              let moved = calendar.date(byAdding: .minute, value: minutes, to: current)
        else { return }

        let dayStart = calendar.startOfDay(for: current)
        let duration = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        let lastStart = dayStart.addingTimeInterval(24 * 3600 - duration)
        let clamped = min(max(moved, dayStart), max(lastStart, dayStart))

        guard clamped != current else { return }

        store.update(todo) {
            $0.assignedDate = clamped
            $0.assignedHasTime = true
        }
    }

    /// Lengthen or shorten a block by `minutes`, holding its start time.
    ///
    /// Writes the duration explicitly even when the to-do had none, since the
    /// point of the keystroke is to give it a length of its own rather than to
    /// keep tracking whatever the default happens to be.
    private func resize(_ todo: Todo, byMinutes minutes: Int) {
        guard let start = todo.assignedDate else { return }

        let current = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        let dayEnd = calendar.startOfDay(for: start).addingTimeInterval(24 * 3600)
        // Never shorter than one nudge step, and never past the end of the day
        // the block starts on.
        let longest = max(dayEnd.timeIntervalSince(start), Self.shortestDuration)
        let proposed = current + Double(minutes) * 60
        let clamped = min(max(proposed, Self.shortestDuration), longest)

        guard clamped != current else { return }

        store.update(todo) { $0.duration = clamped }
    }

    /// Floor for a resized block: below this it stops being readable, and the
    /// grid draws it at its minimum height anyway.
    private static let shortestDuration: TimeInterval = 5 * 60

    private func perform(_ command: KeyboardCommand) {
        switch command {
        case .create:
            createAtNextSlot()

        case .toggleDone:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            handleToggle(todo)

        case .showDetail:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            selectedTodo = todo

        case .schedule:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            schedulingTodo = todo

        case .move:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            movingTodo = todo

        case .duplicate:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            duplicate(todo)

        case .delete:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            store.delete(todo)

        // The calendar has no search field of its own; the lists own that.
        case .search:
            break
        }
    }

    /// Copy a block, leaving the cursor on the copy.
    ///
    /// The copy keeps the original's time, so the two sit exactly on top of one
    /// another — which the grid's overlap layout already handles by splitting
    /// the column between them, and which is the honest thing to show: the user
    /// asked for a second block at that time and now has one.
    private func duplicate(_ todo: Todo) {
        let copy = store.duplicate(todo)
        cursor.select(copy.uuid)
    }

    private func apply(_ destination: MoveDestinationView.Destination, to todo: Todo) {
        switch destination {
        case .none:
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: nil)
        case .space(let id):
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: TodoQueries.space(uuid: id, in: context))
        case .project(let id):
            guard let project = TodoQueries.todo(uuid: id, in: context) else { return }
            _ = store.adopt(todo, asSubtaskOf: project)
        }
    }

    // MARK: Paging

    /// Days (or weeks) laid out as pages so a sideways swipe tracks the finger
    /// and settles with a real animation, the way Calendar.app does.
    ///
    /// Pages are addressed by an integer offset from `pageOrigin` rather than
    /// by date, because `TabView` needs a stable, ordered selection and dates
    /// do not increment uniformly across DST or month ends. The window is
    /// recentred when the user nears either edge, which keeps paging unbounded
    /// without materializing every day.
    @ViewBuilder
    private var pagedContent: some View {
        #if os(iOS)
        TabView(selection: $pageIndex) {
            // Deliberately the whole range rather than a window around the
            // current page: narrowing the `ForEach` as the index moves changes
            // the TabView's children mid-gesture, which visibly breaks the
            // settling animation. Paging stays cheap because each page is
            // cheap — see `creationStrips`, which no longer runs the day's
            // query once per fifteen-minute slot.
            ForEach(pageRange, id: \.self) { offset in
                dayPage(for: offset, isActive: offset == pageIndex)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pageIndex) { _, newValue in
            // Paging is the source of truth; the anchor follows it.
            anchor = date(forPage: newValue)
            recentreIfNeeded()
        }
        .onChange(of: anchor) { _, _ in
            // The Today button and the chevrons move the anchor directly, so
            // the page has to catch up without fighting the user's swipe.
            let target = page(for: anchor)
            if target != pageIndex { pageIndex = target }
        }
        .onChange(of: scale) { _, _ in
            // A page means a day in one scale and a week in the other, so the
            // index has to be recomputed against the date the user was on.
            pageOrigin = anchor
            pageIndex = 0
        }
        #else
        // No paged TabView on macOS; the chevrons in the header are the way to
        // move between days there.
        //
        // Driven off `anchor` rather than `pageIndex`, because nothing moves
        // `pageIndex` on this platform: the swipe that owns it — and the
        // `onChange(of:)` above that syncs it back from the anchor — are both
        // inside the iOS branch. Reading the stale index here left the grid
        // pinned to the page it launched on while the header, the row query
        // and the event fetch all followed the anchor, so the chevrons moved
        // everything *except* the day being drawn.
        dayPage(for: page(for: anchor), isActive: true)
        #endif
    }

    /// One page: the all-day row and the hour grid for that offset.
    ///
    /// `isActive` marks the page actually on screen. The paged branch builds
    /// every page in the window and so has to say which one that is; the macOS
    /// branch builds only the visible page, so it is always the active one.
    private func dayPage(for offset: Int, isActive: Bool) -> some View {
        let days = days(forPage: offset)

        return VStack(spacing: 0) {
            allDayRow(for: days)
            Divider()
            // Only the page on screen builds its long-press creation targets.
            // They exist purely to be touched, and there are 96 of them per
            // day, so building them for all four hundred pages was pure cost.
            timedGrid(for: days, isActive: isActive)
        }
    }

    /// Days shown on a given page.
    private func days(forPage offset: Int) -> [Date] {
        let anchor = date(forPage: offset)

        switch scale {
        case .day:
            return [calendar.startOfDay(for: anchor)]
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else {
                return [calendar.startOfDay(for: anchor)]
            }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
        }
    }

    private func date(forPage offset: Int) -> Date {
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear
        return calendar.date(byAdding: component, value: offset, to: pageOrigin) ?? pageOrigin
    }

    private func page(for date: Date) -> Int {
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear
        let from = scale == .day
            ? calendar.startOfDay(for: pageOrigin)
            : (calendar.dateInterval(of: .weekOfYear, for: pageOrigin)?.start ?? pageOrigin)
        let to = scale == .day
            ? calendar.startOfDay(for: date)
            : (calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date)

        return calendar.dateComponents([component], from: from, to: to).value(for: component) ?? 0
    }

    /// Slide the window when the user approaches an end, so paging never stops.
    private func recentreIfNeeded() {
        guard abs(pageIndex) > pageWindow - 20 else { return }

        let anchor = date(forPage: pageIndex)
        pageOrigin = anchor
        pageIndex = 0
    }

    // MARK: Header

    /// Navigation controls above the grid.
    ///
    /// The Day/Week switch sits here rather than in the toolbar: it belongs
    /// with the other controls that change what the grid is showing, and the
    /// toolbar's top-right corner is no longer where this app puts view
    /// switches.
    private var header: some View {
        VStack(spacing: 8) {
            // A scoped calendar spends its title on the container's name, so
            // the day it is showing has to be said here instead. The week scale
            // already names its days in the column headers below.
            if containerName != nil && scale == .day {
                Text(anchor.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    shift(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Button("Today") { withAnimation(Theme.Animation.panel) { anchor = Date() } }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)

                Button {
                    shift(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)

                Spacer()

                // On a scoped calendar the switch gains a List option, so
                // getting back to the rows is the same control that moves
                // between day and week — going back to the list *is* a change
                // of view, not a step up a hierarchy, and the Back chevron was
                // the only way to do it.
                if onShowList != nil {
                    Picker("View", selection: viewModeSelection) {
                        Text("List").tag(ViewMode.list)
                        ForEach(Scale.allCases) { option in
                            Text(option.label).tag(ViewMode.scale(option))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                } else {
                    Picker("Scale", selection: scaleSelection) {
                        ForEach(Scale.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }

            // Day-of-week columns, so a week view reads at a glance.
            if scale == .week {
                HStack(spacing: 0) {
                    // Matches the hour gutter, so the columns line up with the
                    // grid underneath rather than sitting half a column off.
                    Color.clear.frame(width: Self.gutterWidth, height: 1)

                    ForEach(visibleDays, id: \.self) { day in
                        VStack(spacing: 2) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(day.formatted(.dateTime.day()))
                                .font(.callout)
                                .fontWeight(calendar.isDateInToday(day) ? .bold : .regular)
                                .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : .primary)
                        }
                        // The same per-column inset the grid's day columns
                        // carry, so a header column is exactly as wide as the
                        // column of blocks beneath it.
                        .padding(.horizontal, Self.columnInset)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                // Only the controls above want the pane's margin. The day
                // columns have to start where the grid starts, and taking the
                // margin too left every column offset by it — a constant error
                // that is invisible on a phone in portrait and glaring in
                // landscape, where the columns are wide enough to show it.
                .padding(.horizontal, -Self.headerMargin)
            }
        }
        .padding(.horizontal, Self.headerMargin)
        .padding(.vertical, 10)
    }

    /// Width of the hour labels themselves.
    private static let gutterLabelWidth: CGFloat = 52
    /// Gap between the hour labels and the first day column.
    private static let gutterGap: CGFloat = 6

    /// Total width of the hour-label gutter.
    ///
    /// Derived rather than written out again because two views have to agree on
    /// it: the grid draws the gutter and the week header reserves the same
    /// space to line its columns up with the blocks underneath. Written as a
    /// separate literal, the two drifted apart the moment either was retuned.
    private static let gutterWidth: CGFloat = gutterLabelWidth + gutterGap

    /// Horizontal inset applied to each day column of the grid.
    private static let columnInset: CGFloat = 3

    /// Margin from the pane edge to the header's controls.
    private static let headerMargin: CGFloat = 14

    // MARK: All-day

    /// Untimed scheduled todos, pinned above the grid as the spec requires.
    ///
    /// Capped and scrollable rather than allowed to grow: a day with twenty
    /// undated items would otherwise push the hour grid — the thing the screen
    /// is for — entirely off the bottom of the window.
    private func allDayRow(for days: [Date]) -> some View {
        ScrollView(.vertical) {
            allDayContent(for: days)
        }
        // Only as tall as it needs to be, up to the cap. `ScrollView` takes all
        // the height offered, so without this the row would sit at its maximum
        // even on a day holding one chip.
        .frame(maxHeight: allDayHeight(for: days))
        // A cap that has not been reached is not a scroll view the user should
        // be able to bounce.
        .scrollBounceBehavior(.basedOnSize)
        // The cap is only correct if `chipHeight` matches what a chip actually
        // measures, so one real chip reports its height rather than the layout
        // trusting a constant. Hidden, unhittable, and zero-width, so it costs
        // a measurement and nothing else.
        .background(alignment: .topLeading) { chipHeightProbe }
    }

    /// An off-screen stand-in for a chip, used to learn what one really
    /// measures.
    ///
    /// The row's cap used to be built from a hardcoded 22pt, which was already
    /// short of what a chip takes at the default text size and fell further
    /// behind at every larger one. Being short is what made the bug visible:
    /// the `ScrollView` was framed smaller than its own content, so the chips
    /// painted over the divider and the first hour of the grid.
    ///
    /// Only the two things that set a chip's height are reproduced — the
    /// caption line and the checkbox it sits beside, under the same vertical
    /// padding — rather than building a whole `chip(for:)`, which would drag in
    /// drag-and-drop, a popover, and a to-do to hang them off, none of which
    /// changes the number being measured. The padding is the shared constant
    /// `chip(for:)` uses, so the two cannot drift apart on that axis; the font
    /// and the checkbox scale have to be kept in step by hand.
    private var chipHeightProbe: some View {
        HStack(spacing: 4) {
            TodoCheckboxShape(state: .open, tint: .accentColor, scale: .widget)
            Text("Chip").font(.caption)
        }
        .padding(.vertical, AllDayMetrics.chipPadding)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard height > 0, height != chipHeight else { return }
            chipHeight = height
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Tallest the all-day row is allowed to get: about five chips.
    ///
    /// Measured against the day holding the most, since in the week scale the
    /// columns share one row and the row has to fit the busiest of them.
    private func allDayHeight(for days: [Date]) -> CGFloat {
        let mostChips = days.map { day in
            untimedOn(day).count + allDayEvents(on: day).count
        }.max() ?? 0

        return AllDayMetrics.rowHeight(chipCount: mostChips, chipHeight: chipHeight)
    }

    private func allDayContent(for days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterLabelWidth, alignment: .trailing)
                .padding(.trailing, Self.gutterGap)

            HStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: AllDayMetrics.chipSpacing) {
                        ForEach(untimedOn(day)) { todo in
                            chip(for: todo)
                        }
                        ForEach(allDayEvents(on: day)) { event in
                            allDayEventChip(event)
                        }
                    }
                    // Pinned to the top so a column with one chip lines its
                    // chip up with its neighbours' first, rather than
                    // centring it against the tallest column in the week.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, Self.columnInset)
                    // Dropping into the all-day strip schedules for that day
                    // without a time — the counterpart to dropping onto the
                    // grid, which sets the hour it was dropped at. A
                    // zero-height stack would be unhittable when the day has
                    // nothing in it, so the row's own minimum height stands in.
                    .contentShape(Rectangle())
                    .dropDestination(for: TodoTransfer.self) { items, _ in
                        let dropped = items.compactMap { item in
                            TodoQueries.todo(uuid: item.uuid, in: context)
                        }
                        guard !dropped.isEmpty else { return false }

                        for todo in dropped {
                            store.update(todo) {
                                $0.assignedDate = calendar.startOfDay(for: day)
                                $0.assignedHasTime = false
                                // Dropping onto a day is the user naming one,
                                // which retires the week they had planned it
                                // for — see `Todo.scheduleForWeek`.
                                $0.clearWeekSchedule()
                            }
                        }
                        return true
                    }
                }
            }
        }
        .padding(.vertical, AllDayMetrics.rowPadding)
        // A day with nothing in it still has to be a drop target, so the row
        // keeps a floor of one chip's worth of height. The cap above is a
        // maximum, not a size.
        .frame(minHeight: chipHeight + AllDayMetrics.rowPadding * 2)
    }

    private func chip(for todo: Todo) -> some View {
        let isSelected = selectedBlockID == todo.uuid

        // A plain view rather than a `Button` so `draggable` can claim the
        // long press: a button consumes the touch first and the chip never
        // lifts. Tapping is restored by the explicit tap gesture below.
        return HStack(spacing: 4) {
            // A real checkbox rather than the empty square this used to draw:
            // an all-day chip is a to-do like any other, and the box was
            // already the shape of the control it was standing in for.
            TodoCheckbox(
                state: todo.state,
                tint: tint(for: todo),
                onToggle: { handleToggle(todo) },
                onSelect: { handleSetState(todo, to: $0) },
                scale: .widget
            )
            InlineMarkdownText(
                markdown: todo.title.isEmpty ? "Untitled" : todo.title,
                strikethrough: todo.state == .completed
            )
            .font(.caption)

            Spacer(minLength: 0)

            Button { selectedTodo = todo } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(for: todo))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Details")
            .frame(width: isSelected ? nil : 0)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            .clipped()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, AllDayMetrics.chipPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint(for: todo).opacity(0.2))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                }
        }
        .contentShape(Rectangle())
        // Same as the timed blocks: on macOS the chip is what the editor's
        // popover points at, and without this nothing presents it.
        .todoDetailPopover(for: todo, selection: $selectedTodo)
    // Dragging an all-day chip onto the grid gives it a time. The grid
    // receives it via `dropDestination` below.
        .todoDraggable(todo)
        // Two-stage, matching the timed blocks: select, then open.
        .onTapGesture {
            if isSelected {
                selectedTodo = todo
            } else {
                cursor.select(todo.uuid)
            }
        }
        .contextMenu { blockMenu(for: todo) }
        .accessibilityAddTraits(.isButton)
    }

    /// The context menu behind a long press on anything the calendar lays out.
    ///
    /// Deliberately short, and deliberately not the list's menu: on a calendar
    /// the interesting verbs are about the *slot* — take it off the grid, put a
    /// second one beside it, or get rid of it. Everything else about a to-do is
    /// one tap away in the editor.
    @ViewBuilder
    private func blockMenu(for todo: Todo) -> some View {
        Button {
            store.unschedule(todo)
        } label: {
            Label("Unschedule", systemImage: "calendar.badge.minus")
        }

        Button {
            duplicate(todo)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square.dashed")
        }

        Divider()

        Button(role: .destructive) {
            store.delete(todo)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Timed grid

    private func timedGrid(for days: [Date], isActive: Bool = true) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    hourLabels

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            dayColumn(for: day, isActive: isActive)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            // Open on the working hours rather than at midnight, which is what
            // the top of a 24-hour grid otherwise shows.
            .onAppear {
                proxy.scrollTo(scrollAnchorHour, anchor: .top)
            }
            // The grid stops scrolling for as long as a block is being dragged.
            //
            // An unselected block's gesture is attached *simultaneously* —
            // deliberately, so a swipe starting on a block still scrolls the
            // day — which leaves the `ScrollView` tracking the same touch after
            // the long press has won, free to claim the pan and cancel the drag
            // partway through. Only while a drag is actually in flight, so the
            // scroll-from-a-block gesture is untouched: before the press
            // succeeds there is nothing to disable.
            .scrollDisabled(draggingTodoID != nil)
        }
    }

    /// Hour the grid opens on: an hour before now, so the current time is in
    /// view with a little context above it.
    private var scrollAnchorHour: Int {
        max(calendar.component(.hour, from: Date()) - 1, 0)
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: hourHeight, alignment: .top)
                    // Targets for `scrollTo`, which opens the grid near now.
                    .id(hour)
            }
        }
        .frame(width: Self.gutterLabelWidth)
        .padding(.trailing, Self.gutterGap)
    }

    private func dayColumn(for day: Date, isActive: Bool = true) -> some View {
        let todosOnDay = timedOn(day)
        let eventsOnDay = timedEvents(on: day)
        let slots = layoutSlots(todos: todosOnDay, events: eventsOnDay)

        // Width is measured from a background reader rather than by wrapping the
        // column in a `GeometryReader`: a wrapping one reports no intrinsic
        // height to the enclosing ScrollView, which silently stops the day
        // scrolling.
        return ZStack(alignment: .topLeading) {
            // Hour grid lines. These give the column its height, which is what
            // the ScrollView measures.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Divider().frame(height: hourHeight, alignment: .top)
                }
            }

            // System events sit behind to-dos, since to-dos are the app's
            // own content and stay tappable.
            ForEach(eventsOnDay) { event in
                eventBlock(
                    for: event,
                    on: day,
                    slot: slots["event-\(event.id)"] ?? fullWidth,
                    columnWidth: columnWidth
                )
            }

            if calendar.isDateInToday(day) {
                currentTimeIndicator
            }

            ForEach(todosOnDay) { todo in
                eventBlock(
                    for: todo,
                    on: day,
                    slot: slots["todo-\(todo.uuid.uuidString)"] ?? fullWidth,
                    columnWidth: columnWidth
                )
            }

            // Where the block under the finger will land. Drawn after the
            // blocks so it is never hidden behind one, and before the draft,
            // which is the only thing that outranks it.
            //
            // Drawn by the *destination* column, not the one the block came
            // from: dragged onto another day, the whole point of the indicator
            // is to say which day that is. The origin column asks whether the
            // block still belongs to it, so exactly one column draws it.
            if let dragging = draggingTodo, let origin = draggingOriginDay,
               calendar.isDate(draggedDay(from: origin), inSameDayAs: day) {
                snapIndicator(
                    for: dragging,
                    on: origin,
                    slot: slots["todo-\(dragging.uuid.uuidString)"] ?? fullWidth
                )
            }

            // The placeholder for a long press in progress, drawn last so
            // it sits above whatever is already on the grid.
            if let draft, calendar.isDate(draft.day, inSameDayAs: day) {
                draftBlock(draft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Measured in the background so the reader contributes no layout of its
        // own; a `GeometryReader` wrapped around the column instead reports no
        // intrinsic height and silently stops the day scrolling.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { columnWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in columnWidth = new }
            }
        }
        // Long-pressing empty space creates a to-do at that time, the way
        // Calendar.app creates an event.
        //
        // The press targets are a stack of per-slot strips rather than one
        // gesture over the whole column, because every location-reporting
        // gesture available here is drag-based, and a `DragGesture` — even a
        // simultaneous one — claims the enclosing ScrollView's pan and stops
        // the day scrolling. A strip knows its own time, so a plain long press
        // is enough and scrolling is untouched.
        // Underneath the blocks, not over them.
        //
        // These were an `overlay`, which put 96 live press targets *above* every
        // block in the column. The occupied ones opt out of hit testing, so a
        // press that began on a block still reached it — but a *drag* did not:
        // the moment the finger moved onto a neighbouring empty strip, that
        // strip's own gesture competed for the touch and the block's drag was
        // cancelled. Rescheduling by dragging never worked on either platform
        // for this reason.
        //
        // As a background they are behind the blocks, which is the honest
        // arrangement anyway: a block is a real thing to grab, and the strips
        // are only the empty space around it. Nothing about creation changes —
        // an empty slot has no block in front of it to intercept the press.
        .background { if isActive { creationStrips(for: day) } }
        // Accepts to-dos dropped onto the grid — an all-day chip dragged down
        // from the row above, or something dragged in from the Inbox or a list
        // — scheduling each for the time it was dropped at.
        .dropDestination(for: TodoTransfer.self) { items, location in
            let dropped = items.compactMap { item in
                TodoQueries.todo(uuid: item.uuid, in: context)
            }
            guard !dropped.isEmpty else { return false }

            for todo in dropped {
                schedule(todo, at: location.y, on: day)
            }
            return true
        }
        .padding(.horizontal, Self.columnInset)
    }

    private var fullWidth: CalendarSlot { CalendarSlot(offset: 0, width: 1) }

    /// Lay to-dos and events out together, so a to-do never hides behind a
    /// meeting at the same hour.
    private func layoutSlots(todos: [Todo], events: [CalendarEvent]) -> [String: CalendarSlot] {
        var blocks: [CalendarLayout.Block] = []

        for todo in todos {
            guard let start = todo.assignedDate else { continue }
            let duration = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
            blocks.append(
                .init(
                    id: "todo-\(todo.uuid.uuidString)",
                    start: start,
                    end: start.addingTimeInterval(duration)
                )
            )
        }

        for event in events {
            blocks.append(.init(id: "event-\(event.id)", start: event.start, end: event.end))
        }

        return CalendarLayout.slots(for: blocks)
    }

    /// Turn a y position in the grid into a start time, rounded to the nearest
    /// quarter hour so created items land on tidy boundaries.
    private func time(atY y: CGFloat, on day: Date) -> Date {
        let minutes = max(0, min(24 * 60 - 15, Double(y / hourHeight) * 60))
        let rounded = (minutes / 15).rounded(.down) * 15

        return calendar.date(
            byAdding: .minute,
            value: Int(rounded),
            to: calendar.startOfDay(for: day)
        ) ?? day
    }

    /// Give a previously untimed to-do a time, from a drop onto the grid.
    private func schedule(_ todo: Todo, at y: CGFloat, on day: Date) {
        let start = time(atY: y, on: day)

        // Recorded: a drop from the panel onto the grid takes the row out of
        // the panel's unscheduled list, which is the disappearance undo exists
        // for.
        store.recordingUndo("Schedule", on: todo) {
            store.update(todo) {
                $0.assignedDate = start
                $0.assignedHasTime = true
                // Likewise: a slot on the grid is the most precise answer to
                // "when" there is, so any week plan gives way to it.
                $0.clearWeekSchedule()
                // Only supply a length if it had none, so an existing duration
                // is preserved across the move.
                if $0.duration == nil { $0.duration = settings.defaultEventDuration }
            }
        }

        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Invisible long-press targets, one per creation slot.
    ///
    /// Laid out as a plain `VStack` so each strip's position *is* its time —
    /// no gesture needs to report a touch location, which is what keeps the
    /// enclosing ScrollView scrollable.
    private func creationStrips(for day: Date) -> some View {
        let slotHeight = hourHeight / CGFloat(60 / Self.creationSlotMinutes)
        let slotCount = 24 * (60 / Self.creationSlotMinutes)
        let dayStart = calendar.startOfDay(for: day)
        // Worked out once for the column rather than once per strip. There are
        // 96 strips in a day and the old per-strip check ran the day's whole
        // to-do query each time, so drawing one column meant ninety-six passes
        // over the store — the bulk of what made paging stutter.
        let occupied = occupiedRanges(on: day)

        return VStack(spacing: 0) {
            ForEach(0..<slotCount, id: \.self) { index in
                let start = dayStart.addingTimeInterval(
                    Double(index * Self.creationSlotMinutes) * 60
                )

                let end = start.addingTimeInterval(
                    Double(Self.creationSlotMinutes) * 60
                )

                // A press on an occupied slot belongs to the block there,
                // which has its own drag-to-move gesture, so that slot is left
                // transparent to touches.
                //
                // A real overlap test, not `contains(start)`. Testing only the
                // slot's start left every slot that merely *straddles* a
                // block's edge live — which is exactly where a selected block's
                // resize handle sits, since the handle deliberately hangs past
                // the edge. Holding that handle on macOS therefore reached the
                // strip underneath and created a to-do instead of resizing.
                if occupied.contains(where: { $0.lowerBound < end && $0.upperBound > start }) {
                    Color.clear
                        .frame(height: slotHeight)
                        .allowsHitTesting(false)
                } else {
                    // Not `Color.clear`: a fully transparent shape is not hit
                    // tested, so the press target needs a real (if invisible)
                    // fill.
                    Rectangle()
                        .fill(.black.opacity(0.0001))
                        .frame(height: slotHeight)
                        .contentShape(Rectangle())
                        // A tap on empty grid only clears the selection —
                        // creating from one made every mistimed tap and every
                        // tap-to-dismiss leave a stray to-do behind. Creation
                        // is the long press, which is what Calendar.app asks
                        // for too.
                        //
                        // Attached ahead of the long press so the two do not
                        // race: without the ordering a quick tap can be
                        // delivered to the press recognizer, which on macOS
                        // treats a click held for a frame or two as a press and
                        // creates the block the tap was trying to avoid.
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                draft = nil
                                cursor.select(nil)
                            }
                        )
                        .onLongPressGesture(minimumDuration: Self.createPressDuration) {
                            // Never while a block is being dragged or resized:
                            // the press that is moving that block is still
                            // down, and on macOS it is delivered here too.
                            guard draggingTodoID == nil else { return }
                            createTodo(startingAt: start)
                        }
                }
            }
        }
    }

    /// Granularity of long-press creation, in minutes.
    private static let creationSlotMinutes = 15

    /// How long the grid has to be held before it creates a block.
    ///
    /// Long enough that it cannot be reached by a tap that lingers, since a tap
    /// on empty grid now means "deselect" and the two gestures share a target.
    private static let createPressDuration: Double = 0.25

    /// Spans of the day already covered by a timed to-do.
    ///
    /// System events are ignored: they are read-only here, so creating a to-do
    /// alongside a meeting is a reasonable thing to want.
    private func occupiedRanges(on day: Date) -> [Range<Date>] {
        timedOn(day).compactMap { todo in
            guard let start = todo.assignedDate else { return nil }
            let end = start.addingTimeInterval(
                todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
            )
            guard end > start else { return nil }

            // A selected block's resize handles hang past its edges, so the
            // grid it covers is a little taller than the block itself. Without
            // this margin the outer half of each handle sits over a live
            // creation strip, and holding the handle creates a to-do rather
            // than resizing the block it belongs to.
            let margin = Double(Self.resizeHandleTouchHeight / 2) / Double(hourHeight) * 3600
            return start.addingTimeInterval(-margin)..<end.addingTimeInterval(margin)
        }
    }

    /// Create a block from the app-wide button.
    ///
    /// Long-pressing the grid says *when*; the button does not, so it picks the
    /// next quarter hour — on today when today is on screen, and at the start
    /// of the working day otherwise, since "now" means nothing on a day the
    /// user is only looking at.
    private func createAtNextSlot() {
        let day = calendar.isDate(anchor, inSameDayAs: Date()) ? Date() : anchor

        let start: Date
        if calendar.isDateInToday(day) {
            let minute = calendar.component(.minute, from: day)
            let rounded = (Double(minute) / 15).rounded(.up) * 15
            start = calendar.date(
                byAdding: .minute,
                value: Int(rounded) - minute,
                to: calendar.date(bySetting: .second, value: 0, of: day) ?? day
            ) ?? day
        } else {
            start = calendar.date(
                bySettingHour: 9, minute: 0, second: 0, of: day
            ) ?? day
        }

        createTodo(startingAt: start)
    }

    /// Create a to-do at the pressed time and open it for editing.
    private func createTodo(startingAt start: Date) {
        draft = nil

        let todo = store.createTodo(
            space: creationSpace,
            parent: creationParent,
            assignedDate: start
        )
        store.update(todo) {
            $0.assignedHasTime = true
            $0.duration = settings.defaultEventDuration
        }

        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif

        selectedTodo = todo
    }

    /// The placeholder drawn under the finger during a long press.
    private func draftBlock(_ draft: DraftBlock) -> some View {
        let minutes = CGFloat(calendar.component(.hour, from: draft.start) * 60
            + calendar.component(.minute, from: draft.start))
        let height = max(
            CGFloat(settings.defaultEventDuration / 3600) * hourHeight,
            18
        )

        return VStack(alignment: .leading, spacing: 2) {
            Text("New To-Do")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            if height > 30 {
                Text(draft.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
        }
        .offset(y: minutes / 60 * hourHeight)
        .allowsHitTesting(false)
        .zIndex(2)
    }

    /// A to-do created on a scoped calendar belongs to that container.
    private var creationSpace: Space? {
        if case .space(let id) = destination {
            return TodoQueries.space(uuid: id, in: context)
        }
        if case .project(let id) = destination {
            return TodoQueries.todo(uuid: id, in: context)?.space
        }
        return nil
    }

    private var creationParent: Todo? {
        if case .project(let id) = destination {
            return TodoQueries.todo(uuid: id, in: context)
        }
        return nil
    }

    private func eventBlock(
        for todo: Todo,
        on day: Date,
        slot: CalendarSlot,
        columnWidth: CGFloat
    ) -> some View {
        let isSelected = selectedBlockID == todo.uuid
        let isDragging = draggingTodoID == todo.uuid

        // Geometry follows the finger while a drag is in flight, so the block
        // itself is the preview: it grows from the top edge when the start
        // handle is dragged, from the bottom when the end handle is, and simply
        // travels when the body is. The committed values are unchanged until
        // the gesture ends — see `commitDrag`.
        let baseOffset = verticalOffset(for: todo, on: day)
        let baseHeight = blockHeight(for: todo)
        let liveOffset = baseOffset + (isDragging && dragMode != .resizeEnd ? dragTranslation : 0)
        let liveHeight: CGFloat = {
            guard isDragging else { return baseHeight }
            switch dragMode {
            case .move: return baseHeight
            case .resizeStart: return max(baseHeight - dragTranslation, Self.shortestBlockHeight)
            case .resizeEnd: return max(baseHeight + dragTranslation, Self.shortestBlockHeight)
            }
        }()

        // Deliberately not a `Button`: a button swallows the touch before the
        // long-press-then-drag sequence can recognize, which left blocks
        // untappable to drag. Tap and drag are attached as explicit gestures
        // instead, so both work on the same block.
        return blockLabel(for: todo, height: liveHeight, isSelected: isSelected)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: liveHeight, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint(for: todo).opacity(isDragging ? 0.38 : 0.22))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(tint(for: todo))
                            .frame(width: 2.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    // Ring marks the selected block, whether it was picked with
                    // a tap or with the arrow keys — the same mark the list
                    // rows carry.
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                    }
            }
            .opacity(todo.state.isResolved ? 0.55 : 1)
            .contentShape(Rectangle())
            // The handles are decoration only — no gestures of their own. The
            // one gesture below reads which of them a grab landed on. See
            // `blockGesture`.
            .overlay(alignment: .top) {
                resizeHandle(edge: .top, isVisible: isSelected)
            }
            .overlay(alignment: .bottom) {
                resizeHandle(edge: .bottom, isVisible: isSelected)
            }
            // On macOS the editor is a popover anchored to the thing being
            // edited, and something has to present it. The list rows already
            // do; the calendar did not, so setting
            // `selectedTodo` from a block had nothing listening and the editor
            // never appeared there at all. On iOS this is a no-op and the
            // pushed page still does the work.
            //
            // Attached here, before the gestures and the context menu, for the
            // same reason the resize handles are: `contextMenu` wraps what it
            // is applied to, and an overlay added after it does not survive.
            .todoDetailPopover(for: todo, selection: $selectedTodo)
            // Overlapping blocks cascade rather than stacking invisibly; `depth`
            // keeps the later start drawn on top of the one it insets from.
            .frame(width: max(columnWidth * slot.width - 2, 1), alignment: .topLeading)
            // Sideways travel is passed straight through rather than snapped,
            // so the block stays under the finger between columns; the dashed
            // indicator is what shows which day it will actually land on. Only
            // while moving — a resize has no horizontal meaning.
            .offset(
                x: columnWidth * slot.offset
                    + (isDragging && dragMode == .move ? dragHorizontal : 0),
                y: liveOffset
            )
            .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: isDragging ? 8 : 0)
            // A selected block draws above its neighbours, so its handles and
            // chevron are never buried under the block it overlaps.
            .zIndex(isDragging ? 100 : (isSelected ? 50 : Double(slot.depth)))
            // The tap is two-stage: the first selects, the second opens the
            // editor — the same shape the list's rows have.
            //
            // Ordinary priority, not high: the block contains a checkbox and a
            // chevron, and high priority resolves outermost-first, so it beat
            // both of them and every tap aimed at either opened the editor
            // instead. At ordinary priority the innermost control that was
            // actually hit wins, and the block sees only the taps that missed.
            .gesture(
                TapGesture().onEnded {
                    if isSelected {
                        selectedTodo = todo
                    } else {
                        cursor.select(todo.uuid)
                    }
                }
            )
            .modifier(
                BlockDragModifier(
                    // Fixed for the whole gesture. `isSelected` flips the
                    // instant a drag on an unselected block calls
                    // `cursor.select` — and switching branches here swaps
                    // `simultaneousGesture` for `highPriorityGesture` mid-drag,
                    // tearing out the recognizer that was tracking the finger.
                    // The block then stuck in its dragging appearance with
                    // nothing driving it. A block already being dragged keeps
                    // whichever attachment it started with.
                    isHighPriority: isDragging ? dragStartedSelected : isSelected,
                    gesture: blockGesture(
                        for: todo,
                        on: day,
                        isSelected: isSelected,
                        top: baseOffset,
                        // Base, not live. `liveHeight` changes on every frame of
                        // a resize, which handed SwiftUI a fresh gesture value
                        // continuously and let it rebuild the recognizer under
                        // the finger. The grab band is read from where the block
                        // *was* when the gesture began, which is the geometry
                        // the user actually grabbed.
                        height: baseHeight
                    )
                )
            )
            // No `contextMenu` here, and that is the point.
            //
            // A context menu owns the long press, and on iOS it does not merely
            // observe it: UIKit begins its lift the moment the press starts and
            // cancels whatever else was tracking that touch. That is one
            // mechanism behind two bugs — the block vanishing at the start of a
            // drag (it had been lifted away to be the menu's preview), and, once
            // the drag no longer required a press, the menu still swallowing the
            // press and cancelling the drag before it travelled far enough to
            // count. Dragging a block to reschedule it simply never worked.
            //
            // Dragging is the more valuable gesture on a calendar and it is the
            // one with nowhere else to go, so it keeps the press. The menu moves
            // to the selected block's trailing control — see `blockLabel` — where
            // it is one tap away and competes with nothing.
            .accessibilityAddTraits(.isButton)
    }

    /// A block's contents: the checkbox and chevron a selected block carries,
    /// around the title and time every block shows.
    ///
    /// The checkbox and chevron are mounted at all times and collapsed when the
    /// block is not selected, rather than inserted by an `if`. Two branches of
    /// an `if` are separate views to SwiftUI, so it would cross-fade between
    /// them — and, worse here, tear the block's gesture-bearing subtree out and
    /// rebuild it the instant selection changed, which drops the very tap that
    /// selected it.
    @ViewBuilder
    private func blockLabel(
        for todo: Todo,
        height: CGFloat,
        isSelected: Bool
    ) -> some View {
        let showsControls = isSelected
        // A block at the default fifteen minutes is one line tall, so its
        // controls have to sit *beside* the title rather than above it; a
        // taller one keeps everything hanging from the top edge, where the
        // title is.
        let isSingleLine = height < Self.twoLineHeight

        HStack(alignment: isSingleLine ? .center : .top, spacing: 5) {
            TodoCheckbox(
                state: todo.state,
                tint: tint(for: todo),
                onToggle: { handleToggle(todo) },
                onSelect: { handleSetState(todo, to: $0) },
                scale: .compact
            )
            .frame(width: showsControls ? nil : 0)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)

            VStack(alignment: .leading, spacing: 2) {
                InlineMarkdownText(
                    markdown: todo.title.isEmpty ? "Untitled" : todo.title,
                    strikethrough: todo.state == .completed
                )
                .font(.caption)

                if height > 30, let assigned = todo.assignedDate {
                    Text(assigned.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The way into the full editor, the same affordance an expanded
            // list row grows — and, on a long press, the block's menu.
            //
            // A `Menu` with a primary action rather than a plain button: the
            // calendar has no other home for Unschedule, Duplicate and Delete
            // now that the block itself must keep the long press free for
            // dragging. Tapping still opens the editor, exactly as the list's
            // chevron does; holding gets the verbs.
            Menu {
                blockMenu(for: todo)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(for: todo))
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
            } primaryAction: {
                selectedTodo = todo
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Show Details")
            .frame(width: showsControls ? nil : 0)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
            .clipped()
        }
        .animation(Theme.Animation.rowExpand, value: showsControls)
    }

    /// Shortest a block is drawn while being resized. Matches the floor
    /// `blockHeight(for:)` applies, so a block shrunk to nothing on screen is
    /// the same size as one already at its minimum.
    private static let shortestBlockHeight: CGFloat = 24

    /// Height at which a block has room for a second line, and so lays its
    /// contents out from the top rather than centring them on the title.
    private static let twoLineHeight: CGFloat = 34

    // MARK: Block state changes

    /// The calendar's checkbox, routed through the store exactly as the list's
    /// is, so the subtask rule applies identically on both surfaces.
    private func handleToggle(_ todo: Todo) {
        handleSetState(todo, to: todo.toggledState)
    }

    /// Held as its own typed property rather than written inline in the dialog,
    /// which keeps an optional chain out of an already large `body`.
    private var cascadePrompt: String {
        pendingCascade?.prompt ?? ""
    }

    private func handleSetState(_ todo: Todo, to newState: CompletionState) {
        switch store.setState(todo, to: newState) {
        case .applied:
            break
        case .needsSubtaskConfirmation(let count):
            pendingCascade = PendingCascade(
                todo: todo,
                target: newState,
                blockedCount: count
            )
        }
    }

    // MARK: Dragging blocks

    /// The single gesture on a block: move it, or resize it from either edge.
    ///
    /// One gesture rather than three, and that is the whole design. Handles that
    /// carried their own gestures fought the block's: a handle's touch target is
    /// deliberately larger than the capsule drawn on it, so one grab reached both
    /// views and *both* recognizers ran. Which reported first came down to view
    /// ordering, and every arrangement that made resizing work broke moving or
    /// the reverse. With one recognizer there is nothing to arbitrate — where the
    /// grab landed decides, read once at the start.
    ///
    /// `top` is the block's own offset down the column, and it is what makes that
    /// reading possible. `DragGesture` reports `startLocation` in the space the
    /// gesture is attached in, which here is the day column: a 2:45 PM block
    /// reported y = 911 for something 286 points tall. Naming a coordinate space
    /// on the block does not help — `.coordinateSpace(name:)` defines a space for
    /// a view's *descendants*, and a gesture attached to that same view is not one
    /// of them, so the name silently resolved to the column anyway. Subtracting
    /// the block's own top converts the column reading into a block-relative one
    /// with arithmetic that cannot silently fall back.
    ///
    /// A *selected* block drags immediately. An *unselected* one requires a long
    /// press first, so a plain swipe anywhere on the grid still scrolls the day.
    private func blockGesture(
        for todo: Todo,
        on day: Date,
        isSelected: Bool,
        top: CGFloat,
        height: CGFloat
    ) -> AnyGesture<Void> {
        // Where in the block a grab landed, as one of the three things it can
        // mean. Read from the *start* location every time rather than tracked,
        // so it stays the same for the whole gesture even as the finger — and
        // the block's own live height — move.
        let mode = { (columnY: CGFloat) -> DragMode in
            let y = columnY - top
            let band = min(Self.resizeHandleTouchHeight / 2, height / 3)
            if y <= band { return .resizeStart }
            if y >= height - band { return .resizeEnd }
            return .move
        }

        if isSelected {
            return AnyGesture(
                DragGesture(minimumDistance: 4)
                    // `updating` is the cancellation net. `onEnded` does not run
                    // when a recognizer is cancelled — by a scroll view claiming
                    // the touch, or by the view tree changing under it — which
                    // is what left a block stuck in its dragging appearance with
                    // no gesture still driving it. SwiftUI always resets
                    // `@GestureState`, so `isTracking` falling back to false is
                    // the one signal that arrives either way.
                    .updating($isTracking) { _, tracking, _ in tracking = true }
                    .onChanged { value in
                        begin(mode(value.startLocation.y), on: todo)
                        dragTranslation = value.translation.height
                        dragHorizontal = value.translation.width
                    }
                    .onEnded { _ in commitDrag(todo, on: day) }
                    .map { _ in () }
            )
        }

        // Unselected blocks have no handles showing, so every drag is a move.
        return AnyGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($isTracking) { value, tracking, _ in
                    // Only once the press has succeeded and the drag has taken
                    // over; the press phase alone is not a drag in flight.
                    if case .second = value { tracking = true }
                }
                .onChanged { value in
                    guard case .second(_, let drag) = value else { return }
                    begin(.move, on: todo)
                    dragTranslation = drag?.translation.height ?? 0
                    dragHorizontal = drag?.translation.width ?? 0
                }
                .onEnded { _ in commitDrag(todo, on: day) }
                .map { _ in () }
        )
    }

    /// The grab handle drawn at a selected block's top or bottom edge.
    ///
    /// Decoration only: it carries no gesture and is not hit tested. The block's
    /// single drag gesture is what notices a grab landed on an edge — see
    /// `blockGesture` — so the handle's job is just to show the user where those
    /// edges are.
    private func resizeHandle(edge: VerticalEdge, isVisible: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: Self.resizeHandleWidth, height: Self.resizeHandleThickness)
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            }
            .opacity(isVisible ? 1 : 0)
            // Centred on the edge rather than tucked inside it, so it marks
            // exactly where the block starts or ends.
            .offset(y: edge == .top ? -Self.resizeHandleThickness / 2 : Self.resizeHandleThickness / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let resizeHandleWidth: CGFloat = 26
    private static let resizeHandleThickness: CGFloat = 5
    /// How deep a band at each edge of a selected block counts as "grabbing the
    /// handle" rather than the block itself.
    ///
    /// Much larger than the capsule drawn there, which is only five points tall
    /// — Calendar does the same, and without the extra room the handle is
    /// visible but not reliably grabbable on a phone. Trimmed on a short block
    /// so the middle always stays wide enough to drag: at the default fifteen
    /// minutes a block is only about twenty-four points tall.
    private static let resizeHandleTouchHeight: CGFloat = 34

    /// Mark the start of a drag, once per gesture.
    ///
    /// Selection moves to the block being dragged: dragging something is a
    /// clearer statement of intent than the tap that would otherwise have been
    /// needed to select it, and leaving the ring on a different block while
    /// this one moves reads as a bug.
    ///
    /// Resizing outranks moving. The handles sit on the block's edges and their
    /// touch targets are deliberately larger than the capsules drawn there, so
    /// a grab aimed at a handle also lands on the block — whose own drag runs
    /// `simultaneousGesture` and would otherwise claim it first and turn every
    /// attempted resize into a move.
    private func begin(_ mode: DragMode, on todo: Todo) {
        // One gesture drives this now, so the mode it picked at the start is the
        // mode for the whole drag: nothing else can arrive to contest it, and
        // re-reading it mid-drag would let the finger leaving the edge band turn
        // a resize into a move.
        guard draggingTodoID != todo.uuid else { return }

        // Recorded here, applied in `commitDrag`. Moving the cursor *now* is
        // what made dragging a block impossible: `isSelected` feeds the block's
        // label, its handles and its `zIndex`, so selecting it mid-gesture
        // rebuilt the very subtree the recognizer was attached to and cancelled
        // it. The drag arrived once with a nil value and then stopped dead,
        // which is exactly the block refusing to follow the finger.
        //
        // The selection still lands — dragging something is a clear statement
        // of intent, and leaving the ring on another block would read as a bug
        // — it just waits until the gesture that depends on it is over.
        dragStartedSelected = cursor.selection == todo.uuid
        draggingTodoID = todo.uuid
        dragMode = mode
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Write the drag's result back and clear the in-flight state.
    private func commitDrag(_ todo: Todo, on day: Date) {
        // Only the gesture that actually took this block writes anything. Both
        // the block's drag and a handle's end here, and whichever ends second
        // must not undo the first or act on a block it never claimed.
        guard draggingTodoID == todo.uuid else { return }

        defer {
            draggingTodoID = nil
            dragTranslation = 0
            dragHorizontal = 0
            dragMode = .move
            // The selection `begin` deliberately did not make — see there. In
            // the `defer` rather than at the end, so a drag that moved nothing
            // still selects the block the user grabbed: that is the same
            // outcome the tap would have produced, and by here the gesture is
            // over, so rebuilding the block costs nothing.
            cursor.select(todo.uuid)
        }

        guard let proposal = dragProposal(for: todo, on: day) else { return }

        // Read before the `defer` above resets it, and into a local so the name
        // resolves to this view's state rather than a SwiftUI type of the same
        // name.
        let wasResize = dragMode == .resizeStart || dragMode == .resizeEnd

        // Moving a block to another day takes it off the page being shown, and
        // the exact slot it came from is hard to hit again by hand.
        store.recordingUndo(wasResize ? "Resize" : "Move", on: todo) {
            store.update(todo) {
                $0.assignedDate = proposal.start
                $0.assignedHasTime = true
                $0.duration = proposal.duration
            }
        }

        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Where the block in flight will land, snapped to the grid.
    ///
    /// One definition for both the write on drop and the ghost drawn under the
    /// finger, so what the user is shown is exactly what they get. Returns nil
    /// when the drag would change nothing.
    private func dragProposal(for todo: Todo, on day: Date) -> (start: Date, duration: TimeInterval)? {
        guard let current = todo.assignedDate else { return nil }

        let duration = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        // The day the block would land on, which on a week grid is not
        // necessarily the one it started in — see `draggedDay(from:)`.
        //
        // Moving only. Resizing sideways has no meaning: the handles change how
        // long a block runs, and letting a stray horizontal wobble also throw it
        // onto Tuesday would be a surprise, not a feature.
        let targetDay = dragMode == .move ? draggedDay(from: day) : day
        let dayStart = calendar.startOfDay(for: targetDay)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        let snappedMinutes = snappedMinutes(for: dragTranslation)
        let changesDay = !calendar.isDate(targetDay, inSameDayAs: day)

        // A pure sideways drag is a real move even though the time of day is
        // unchanged, so the "nothing happened" test has to consider both axes.
        guard snappedMinutes != 0 || changesDay else { return nil }
        let shift = TimeInterval(snappedMinutes * 60)

        switch dragMode {
        case .move:
            // Clamped to the day rather than dropped when it would spill past
            // midnight, so an overshoot lands at the edge instead of silently
            // doing nothing.
            let lastStart = dayEnd.addingTimeInterval(-duration)
            // Rebuilt on the target day rather than shifted by whole days: the
            // time of day is what carries over, and adding 24-hour multiples
            // would drift across a daylight-saving boundary.
            let movedInDay = current.addingTimeInterval(shift)
            let moved = changesDay
                ? combine(day: dayStart, timeOf: movedInDay)
                : movedInDay
            let clamped = min(max(moved, dayStart), max(lastStart, dayStart))
            guard clamped != current else { return nil }
            return (clamped, duration)

        case .resizeStart:
            // The end is what stays put: dragging the top edge changes when the
            // block begins, and therefore how long it runs.
            let end = current.addingTimeInterval(duration)
            let latestStart = end.addingTimeInterval(-Self.shortestDuration)
            let moved = min(max(current.addingTimeInterval(shift), dayStart), latestStart)
            let newDuration = end.timeIntervalSince(moved)
            guard moved != current else { return nil }
            return (moved, newDuration)

        case .resizeEnd:
            let longest = max(dayEnd.timeIntervalSince(current), Self.shortestDuration)
            let proposed = min(max(duration + shift, Self.shortestDuration), longest)
            guard proposed != duration else { return nil }
            return (current, proposed)
        }
    }

    /// The day a drag has carried the block to, given the day it started on.
    ///
    /// On a single-day grid this is always the day itself: there is nowhere
    /// sideways to go, and treating a horizontal wobble as a day change would
    /// silently reschedule work the user only meant to nudge.
    ///
    /// On a week grid the columns are all `columnWidth` wide and evenly spaced,
    /// so how far across the finger has travelled divides straight into a
    /// number of columns. The result is clamped to the week on screen — the
    /// grid does not page while a block is held, so there is no way to see, or
    /// aim at, a day outside it.
    private func draggedDay(from day: Date) -> Date {
        guard scale == .week, columnWidth > 0 else { return day }

        let columns = (dragHorizontal / columnWidth).rounded()
        guard columns != 0 else { return day }

        let days = visibleDays
        guard let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: day) })
        else { return day }

        let target = min(max(index + Int(columns), 0), days.count - 1)
        return days[target]
    }

    /// A date on `day` at the same wall-clock time as `timeOf`.
    ///
    /// Used instead of adding whole days so a move across a daylight-saving
    /// boundary keeps the time the user is looking at: 9am dragged to Sunday is
    /// 9am on Sunday, not 8am or 10am.
    private func combine(day: Date, timeOf source: Date) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: source)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        ) ?? day
    }

    /// The block currently in flight, if any.
    private var draggingTodo: Todo? {
        guard let id = draggingTodoID else { return nil }
        return TodoQueries.todo(uuid: id, in: context)
    }

    /// The day the block in flight started on.
    ///
    /// Read from the to-do's own date rather than tracked as drag state,
    /// because nothing writes that date until the drop: while a drag is in
    /// flight the stored day is still the one it came from, which is exactly
    /// what `draggedDay(from:)` needs as its origin.
    private var draggingOriginDay: Date? {
        draggingTodo?.assignedDate.map { calendar.startOfDay(for: $0) }
    }

    /// The outline showing where a dragged block will snap to.
    ///
    /// Drawn as a dashed frame at the proposed slot with the time it would land
    /// on, so the answer to "where is this going" is on the grid itself rather
    /// than inferred from the block travelling under the finger — which moves
    /// continuously and does not, on its own, say which quarter hour it will
    /// round to.
    @ViewBuilder
    private func snapIndicator(for todo: Todo, on day: Date, slot: CalendarSlot) -> some View {
        if let proposal = dragProposal(for: todo, on: day) {
            let minutes = CGFloat(calendar.component(.hour, from: proposal.start) * 60
                + calendar.component(.minute, from: proposal.start))
            let height = max(CGFloat(proposal.duration / 3600) * hourHeight, Self.shortestBlockHeight)

            Text(snapLabel(for: proposal))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.top, 2)
                // An exact height, not a minimum: the outline stands for a span
                // of time, so it has to be exactly as tall as that span. Given
                // a `minHeight` inside the column's ZStack it stretched to the
                // full 24 hours instead, which said nothing about where the
                // block was going.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: height, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                            )
                    }
            }
            .frame(width: max(columnWidth * slot.width - 2, 1), alignment: .topLeading)
            .offset(x: columnWidth * slot.offset, y: minutes / 60 * hourHeight)
            .allowsHitTesting(false)
            .zIndex(90)
        }
    }

    /// What the snap outline says: the time it will start at, and — while the
    /// length is what is being changed — how long it will run.
    private func snapLabel(for proposal: (start: Date, duration: TimeInterval)) -> String {
        let start = proposal.start.formatted(date: .omitted, time: .shortened)

        switch dragMode {
        case .move:
            return start
        case .resizeStart, .resizeEnd:
            let end = proposal.start.addingTimeInterval(proposal.duration)
            return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// A drag distance in points, as whole snap steps of minutes.
    private func snappedMinutes(for translation: CGFloat) -> Int {
        let minutes = Double(translation / hourHeight) * 60
        return Int((minutes / Double(Self.snapMinutes)).rounded()) * Self.snapMinutes
    }

    /// Granularity a dragged or resized block snaps to.
    private static let snapMinutes = 15

    private var currentTimeIndicator: some View {
        let now = Date()
        let minutes = CGFloat(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))

        return Rectangle()
            .fill(Color.red)
            .frame(height: 1.5)
            .overlay(alignment: .leading) {
                Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: -3)
            }
            .offset(y: minutes / 60 * hourHeight)
    }

    // MARK: Geometry

    private func verticalOffset(for todo: Todo, on day: Date) -> CGFloat {
        guard let assigned = todo.assignedDate else { return 0 }
        let minutes = CGFloat(calendar.component(.hour, from: assigned) * 60
            + calendar.component(.minute, from: assigned))
        return minutes / 60 * hourHeight
    }

    /// Height from the todo's duration, falling back to the configured default
    /// — 15 minutes unless the user changed it.
    ///
    /// Floored at a comfortable tap target: at the default duration a block is
    /// only about 13pt tall, which is too small to reliably hit or drag.
    private func blockHeight(for todo: Todo) -> CGFloat {
        let seconds = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        return max(CGFloat(seconds / 3600) * hourHeight, 24)
    }

    /// Same resolution as the list rows, so a color change shows up in both.
    private func tint(for todo: Todo) -> Color {
        todo.resolvedColorHex.map { Color(hex: $0) } ?? .accentColor
    }

    // MARK: System calendar events

    /// Changes to any of these mean the event query has to run again.
    private var eventReloadKey: String {
        let days = visibleDays
        let start = days.first ?? anchor
        let end = days.last ?? anchor
        let calendars = settings.visibleCalendars?.joined(separator: ",") ?? "default"
        return "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(showsCalendarEvents)-\(calendars)"
    }

    private func reloadEvents() async {
        guard showsCalendarEvents else {
            eventStore.clear()
            return
        }

        // Ask on first use, so enabling the toggle in settings is all it takes.
        if !eventStore.hasAccess {
            guard await eventStore.requestAccess() else { return }
        }

        guard let first = visibleDays.first, let last = visibleDays.last,
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: last)
        else { return }

        await eventStore.loadEvents(
            from: calendar.startOfDay(for: first),
            to: rangeEnd,
            calendarIdentifiers: settings.visibleCalendars
        )
    }

    /// All-day system events falling on a given day.
    private func allDayEvents(on day: Date) -> [CalendarEvent] {
        // `eventStore` is shared, so a scoped calendar must not render events
        // another destination loaded before it.
        guard showsCalendarEvents else { return [] }

        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        return eventStore.events.filter { event in
            // An all-day event can span days, so overlap is the right test.
            event.isAllDay && event.start < dayEnd && event.end > dayStart
        }
    }

    /// Timed system events starting on a given day.
    private func timedEvents(on day: Date) -> [CalendarEvent] {
        guard showsCalendarEvents else { return [] }

        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        return eventStore.events
            .filter { !$0.isAllDay && $0.start >= dayStart && $0.start < dayEnd }
            .sorted { $0.start < $1.start }
    }

    /// Read-only block for a system calendar event.
    ///
    /// Styled to read as "not a to-do": no checkbox, a dashed-free flat fill in
    /// the source calendar's own color, and no tap target.
    private func eventBlock(
        for event: CalendarEvent,
        on day: Date,
        slot: CalendarSlot,
        columnWidth: CGFloat
    ) -> some View {
        let color = Color(hex: event.colorHex)
        let minutes = CGFloat(calendar.component(.hour, from: event.start) * 60
            + calendar.component(.minute, from: event.start))
        let height = max(CGFloat(event.duration / 3600) * hourHeight, 18)

        return VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.caption)
                .lineLimit(height > 30 ? 2 : 1)
                .foregroundStyle(color)

            if height > 34 {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(color.opacity(0.75))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.13))
                .overlay(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.7)).frame(width: 2.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(width: max(columnWidth * slot.width - 2, 1), alignment: .topLeading)
        .offset(x: columnWidth * slot.offset, y: minutes / 60 * hourHeight)
        .zIndex(Double(slot.depth))
        .allowsHitTesting(false)
        .accessibilityLabel("Calendar event: \(event.title)")
    }

    private func allDayEventChip(_ event: CalendarEvent) -> some View {
        let color = Color(hex: event.colorHex)
        return Text(event.title)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, AllDayMetrics.chipPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.13))
            }
    }

    // MARK: Dates

    /// Days on the page currently shown. Used by the week header and to decide
    /// which range of events to load; `days(forPage:)` is the single definition.
    private var visibleDays: [Date] {
        days(forPage: page(for: anchor))
    }

    private func shift(by amount: Int) {
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear
        if let next = calendar.date(byAdding: component, value: amount, to: anchor) {
            withAnimation(Theme.Animation.panel) { anchor = next }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "" }
        return date.formatted(.dateTime.hour())
    }

    private var navigationTitle: String {
        // A scoped calendar names its container instead of the dates: it is
        // reached from that list, the header below already says which days are
        // on screen, and "Groceries" is what tells the user this grid is not
        // the whole calendar.
        if let containerName { return containerName }

        switch scale {
        case .day:
            return anchor.formatted(.dateTime.weekday(.wide).month().day())
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return "Week" }
            let end = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
            return "\(week.start.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
        }
    }

    /// Name of the space or project this calendar is scoped to, if any.
    private var containerName: String? {
        switch destination {
        case .space(let id):
            return TodoQueries.space(uuid: id, in: context)?.name
        case .project(let id):
            return TodoQueries.todo(uuid: id, in: context)?.title
        default:
            return nil
        }
    }
}

/// Attaches a block's drag gesture at whichever priority that block needs.
///
/// A *selected* block's drag is a plain one, and a plain drag attached
/// simultaneously loses to the enclosing `ScrollView`, which claims the pan on
/// both platforms — so the block never moved. High priority takes it back.
///
/// An *unselected* block keeps its gesture simultaneous, because there it is a
/// long press followed by a drag: the press is what disambiguates it from a
/// scroll, and claiming the touch outright would stop the grid scrolling
/// whenever a finger happened to start on a block.
///
/// A `ViewModifier` rather than an `if` at the call site: branching there would
/// give the two cases different view types, so every change of selection would
/// tear the block's subtree down mid-gesture. Branching *inside* a modifier is
/// safe — the host view's type does not change with it.
private struct BlockDragModifier: ViewModifier {
    let isHighPriority: Bool
    let gesture: AnyGesture<Void>

    @ViewBuilder
    func body(content: Content) -> some View {
        // One attachment, not two masked with `including:`. Handing the same
        // gesture value to two attachments gives SwiftUI two recognizers
        // sharing one piece of state; they conflict, and neither ever resolves.
        if isHighPriority {
            content.highPriorityGesture(gesture)
        } else {
            content.simultaneousGesture(gesture)
        }
    }
}

#if DEBUG
private struct CalendarPreviewHost: View {
    @State private var selected: Todo?

    var body: some View {
        NavigationStack {
            CalendarView(selectedTodo: $selected)
        }
    }
}

#Preview("Calendar") {
    // Untimed to-dos sit in the all-day header; timed ones lay out on the grid.
    CalendarPreviewHost()
        .previewEnvironment()
}
#endif
