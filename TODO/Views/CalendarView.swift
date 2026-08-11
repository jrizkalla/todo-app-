import SwiftUI
import SwiftData

/// Day or week calendar.
///
/// Scheduled todos without a time sit in a header row; timed todos are laid out
/// against the hour grid like calendar events, using their duration or the
/// configured default.
struct CalendarView: View {
    enum Scale: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var label: String { self == .day ? "Day" : "Week" }
    }

    @Binding var selectedTodo: Todo?

    /// The list the calendar was opened from.
    ///
    /// Determines both which to-dos are laid out and whether outside calendar
    /// events appear at all: from a space or project the calendar is about that
    /// container's work, so events from the user's calendars would be noise.
    var destination: ListDestination = .today

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query private var todos: [Todo]
    @Query private var spaces: [Space]

    /// Day or week, and the day being shown.
    ///
    /// Owned by `RootView` when the calendar is a tab, so tapping the summary's
    /// schedule card can open the calendar *on today* rather than wherever the
    /// user last left it. The local defaults keep the view usable on its own —
    /// in previews, and scoped to a space or project.
    var anchorDate: Binding<Date>?
    var scaleBinding: Binding<Scale>?

    /// Incremented by the app-wide create button; the calendar answers by
    /// creating a block at the next quarter hour. See `createAtNextSlot`.
    var createRequest: Binding<Int>?

    /// Called to go back to the list this calendar was opened from.
    ///
    /// Set only by the scoped calendars, which are one of two ways of reading
    /// the same list; the Calendar tab is a destination in its own right and
    /// has nothing to return to.
    var onShowList: (() -> Void)?

    @State private var localScale: Scale = .day
    @State private var localAnchor = Date()
    @State private var eventStore = CalendarEventStore.shared

    /// The side panel, which a scoped calendar points at its own list.
    @State private var panelScope = SidePanelScopeModel.shared
    /// This calendar's claim on the panel, held while it is on screen.
    @State private var sidePanelClaim: UUID?

    /// The to-do being dragged to a new time, and how far it has moved.
    @State private var draggingTodoID: UUID?
    @State private var dragTranslation: CGFloat = 0
    /// A block sketched under the finger while a long press is held, before the
    /// to-do is actually created. Mirrors the placeholder Calendar.app shows.
    @State private var draft: DraftBlock?
    /// Width of one day column, measured from the laid-out grid so overlapping
    /// blocks can be positioned as fractions of it.
    @State private var columnWidth: CGFloat = 0

    /// A not-yet-created to-do being sketched by a long press.
    private struct DraftBlock: Equatable {
        let day: Date
        /// Start time, snapped to the grid.
        var start: Date
    }

    /// Where the arrow keys are pointing, over the blocks on the visible page.
    @State private var cursor = KeyboardCursor()
    /// The to-do whose scheduling panel is open, from Cmd+S.
    @State private var schedulingTodo: Todo?
    /// The to-do whose "move to" picker is open, from Cmd+M.
    @State private var movingTodo: Todo?

    /// Page currently shown, as an offset from `pageOrigin`.
    @State private var pageIndex = 0
    /// Date that page 0 refers to; moved when the window is recentred.
    @State private var pageOrigin = Date()

    /// How many pages exist either side of the origin. Large enough that
    /// recentring is invisible, small enough to stay cheap.
    private let pageWindow = 200

    private var pageRange: ClosedRange<Int> { -pageWindow...pageWindow }


    /// Height of one hour in the grid.
    private let hourHeight: CGFloat = 52

    private var calendar: Calendar { settings.calendar }
    private var store: TodoStore { TodoStore(context: context) }

    /// The externally-owned value when there is one, else the local state.
    private var scale: Scale {
        get { scaleBinding?.wrappedValue ?? localScale }
        nonmutating set {
            if let scaleBinding { scaleBinding.wrappedValue = newValue } else { localScale = newValue }
        }
    }

    private var anchor: Date {
        get { anchorDate?.wrappedValue ?? localAnchor }
        nonmutating set {
            if let anchorDate { anchorDate.wrappedValue = newValue } else { localAnchor = newValue }
        }
    }

    /// Binding form, for the picker.
    private var scaleSelection: Binding<Scale> {
        scaleBinding ?? $localScale
    }

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

    /// To-dos this calendar lays out, narrowed to the container it was opened
    /// from.
    private var scopedTodos: [Todo] {
        TodoQueries.calendarScope(todos, for: destination)
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
        // A scoped calendar takes over the side panel for as long as it is on
        // screen, so the grid's dated work and the panel's undated work make up
        // the whole container between them. The Calendar *tab* claims nothing:
        // it is unscoped, and the Inbox is what belongs beside it.
        //
        // Tied to `destination` as well as to appearing, because the Lists tab
        // reuses one pushed calendar as the sidebar selection moves under it.
        .onAppear { claimSidePanel() }
        .onChange(of: destination) { _, _ in claimSidePanel() }
        .onDisappear {
            guard let token = sidePanelClaim else { return }
            sidePanelClaim = nil
            panelScope.release(token)
        }
        // The app-wide button asks; the calendar answers by blocking out the
        // next quarter hour on the day being shown.
        .onChange(of: createRequest?.wrappedValue) { _, _ in createAtNextSlot() }
        // Up and down step through the day's blocks in time order; left and
        // right move between days, which is what the arrows mean on a grid.
        .onKeyPress(.upArrow) { moveCursor(.up) }
        .onKeyPress(.downArrow) { moveCursor(.down) }
        .onKeyPress(.leftArrow) { shift(by: -1); return .handled }
        .onKeyPress(.rightArrow) { shift(by: 1); return .handled }
        .onKeyPress(.return) {
            guard let todo = cursorTodo else { return .ignored }
            selectedTodo = todo
            return .handled
        }
        .keyboardCommands(isActive: cursor.selection != nil || selectedTodo != nil) { command in
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
                    store.update(todo) {
                        $0.assignedDate = date
                        $0.assignedHasTime = hasTime
                    }
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
    }

    // MARK: Side panel

    /// Point the side panel at this calendar's list, if it has one.
    ///
    /// Only spaces and projects claim it. The cross-cutting destinations are
    /// what the Calendar tab already shows unscoped, and their "unscheduled
    /// remainder" would be every undated to-do in the app — which is not a
    /// useful list, and is not what the Inbox sitting there already means.
    private func claimSidePanel() {
        switch destination {
        case .space, .project:
            sidePanelClaim = panelScope.claim(destination)
        default:
            break
        }
    }

    // MARK: Keyboard

    /// Every to-do the arrow keys can land on, in the order they read on the
    /// page: all-day items first, then timed blocks by start time.
    ///
    /// Scoped to the days actually on screen, so the cursor never selects
    /// something the user cannot see.
    private var navigableTodoIDs: [UUID] {
        let days = days(forPage: pageIndex)

        return days.flatMap { day in
            // `timed` already comes back in start order, which is the order the
            // blocks are drawn down the column.
            TodoQueries.untimed(scopedTodos, on: day, calendar: calendar).map(\.uuid)
                + TodoQueries.timed(scopedTodos, on: day, calendar: calendar).map(\.uuid)
        }
    }

    private var cursorTodo: Todo? {
        guard let id = cursor.selection else { return nil }
        return todos.first { $0.uuid == id }
    }

    private func moveCursor(_ direction: KeyboardCursor.Direction) -> KeyPress.Result {
        var next = cursor
        guard next.move(direction, in: navigableTodoIDs) else { return .ignored }
        cursor = next
        return .handled
    }

    private func perform(_ command: KeyboardCommand) {
        switch command {
        case .create:
            createAtNextSlot()

        case .toggleDone:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            _ = store.toggle(todo)

        case .showDetail:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            selectedTodo = todo

        case .schedule:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            schedulingTodo = todo

        case .move:
            guard let todo = cursorTodo ?? selectedTodo else { return }
            movingTodo = todo

        // The calendar has no search field of its own; the lists own that.
        case .search:
            break
        }
    }

    private func apply(_ destination: MoveDestinationView.Destination, to todo: Todo) {
        switch destination {
        case .none:
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: nil)
        case .space(let id):
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: spaces.first { $0.uuid == id })
        case .project(let id):
            guard let project = todos.first(where: { $0.uuid == id }) else { return }
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
                dayPage(for: offset)
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
        dayPage(for: pageIndex)
        #endif
    }

    /// One page: the all-day row and the hour grid for that offset.
    private func dayPage(for offset: Int) -> some View {
        let days = days(forPage: offset)

        return VStack(spacing: 0) {
            allDayRow(for: days)
            Divider()
            // Only the page on screen builds its long-press creation targets.
            // They exist purely to be touched, and there are 96 of them per
            // day, so building them for all four hundred pages was pure cost.
            timedGrid(for: days, isActive: offset == pageIndex)
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
    private func allDayRow(for days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterLabelWidth, alignment: .trailing)
                .padding(.trailing, Self.gutterGap)

            HStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        ForEach(TodoQueries.untimed(scopedTodos, on: day, calendar: calendar)) { todo in
                            chip(for: todo)
                        }
                        ForEach(allDayEvents(on: day)) { event in
                            allDayEventChip(event)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.columnInset)
                    // Dropping into the all-day strip schedules for that day
                    // without a time — the counterpart to dropping onto the
                    // grid, which sets the hour it was dropped at. A
                    // zero-height stack would be unhittable when the day has
                    // nothing in it, so the row's own minimum height stands in.
                    .contentShape(Rectangle())
                    .dropDestination(for: TodoTransfer.self) { items, _ in
                        let dropped = items.compactMap { item in
                            todos.first { $0.uuid == item.uuid }
                        }
                        guard !dropped.isEmpty else { return false }

                        for todo in dropped {
                            store.update(todo) {
                                $0.assignedDate = calendar.startOfDay(for: day)
                                $0.assignedHasTime = false
                            }
                        }
                        return true
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 36)
    }

    private func chip(for todo: Todo) -> some View {
        // A plain view rather than a `Button` so `draggable` can claim the
        // long press: a button consumes the touch first and the chip never
        // lifts. Tapping is restored by the explicit tap gesture below.
        HStack(spacing: 4) {
            Image(systemName: "square")
                .font(.caption)
            InlineMarkdownText(markdown: todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.caption)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint(for: todo).opacity(0.2))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            Color.accentColor,
                            lineWidth: cursor.selection == todo.uuid ? 2 : 0
                        )
                }
        }
        .contentShape(Rectangle())
    // Dragging an all-day chip onto the grid gives it a time. The grid
    // receives it via `dropDestination` below.
        .todoDraggable(todo)
        .onTapGesture {
            cursor.select(todo.uuid)
            selectedTodo = todo
        }
        .accessibilityAddTraits(.isButton)
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
        let todosOnDay = TodoQueries.timed(scopedTodos, on: day, calendar: calendar)
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
        .overlay { if isActive { creationStrips(for: day) } }
        // Accepts to-dos dropped onto the grid — an all-day chip dragged down
        // from the row above, or something dragged in from the Inbox or a list
        // — scheduling each for the time it was dropped at.
        .dropDestination(for: TodoTransfer.self) { items, location in
            let dropped = items.compactMap { item in
                todos.first { $0.uuid == item.uuid }
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

        store.update(todo) {
            $0.assignedDate = start
            $0.assignedHasTime = true
            // Only supply a length if it had none, so an existing duration is
            // preserved across the move.
            if $0.duration == nil { $0.duration = settings.defaultEventDuration }
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

                // A press on an occupied slot belongs to the block there,
                // which has its own drag-to-move gesture, so that slot is left
                // transparent to touches.
                if occupied.contains(where: { $0.contains(start) }) {
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
                        .onLongPressGesture(minimumDuration: 0.4) {
                            createTodo(startingAt: start)
                        } onPressingChanged: { pressing in
                            draft = pressing ? DraftBlock(day: day, start: start) : nil
                        }
                }
            }
        }
    }

    /// Granularity of long-press creation, in minutes.
    private static let creationSlotMinutes = 15

    /// Spans of the day already covered by a timed to-do.
    ///
    /// System events are ignored: they are read-only here, so creating a to-do
    /// alongside a meeting is a reasonable thing to want.
    private func occupiedRanges(on day: Date) -> [Range<Date>] {
        TodoQueries.timed(scopedTodos, on: day, calendar: calendar).compactMap { todo in
            guard let start = todo.assignedDate else { return nil }
            let end = start.addingTimeInterval(
                todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
            )
            guard end > start else { return nil }
            return start..<end
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
            return spaces.first { $0.uuid == id }
        }
        if case .project(let id) = destination {
            return todos.first { $0.uuid == id }?.space
        }
        return nil
    }

    private var creationParent: Todo? {
        if case .project(let id) = destination {
            return todos.first { $0.uuid == id }
        }
        return nil
    }

    private func eventBlock(
        for todo: Todo,
        on day: Date,
        slot: CalendarSlot,
        columnWidth: CGFloat
    ) -> some View {
        let baseOffset = verticalOffset(for: todo, on: day)
        let height = blockHeight(for: todo)
        let isDragging = draggingTodoID == todo.uuid
        let dragOffset = isDragging ? dragTranslation : 0

        // Deliberately not a `Button`: a button swallows the touch before the
        // long-press-then-drag sequence can recognize, which left blocks
        // untappable to drag. Tap and drag are attached as explicit gestures
        // instead, so both work on the same block.
        return VStack(alignment: .leading, spacing: 2) {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint(for: todo).opacity(isDragging ? 0.38 : 0.22))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tint(for: todo))
                        .frame(width: 2.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                // Ring marks where the arrow keys are, the same way the list
                // rows do.
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            Color.accentColor,
                            lineWidth: cursor.selection == todo.uuid ? 2 : 0
                        )
                }
        }
        .opacity(todo.state.isResolved ? 0.55 : 1)
        .contentShape(Rectangle())
        // Overlapping blocks cascade rather than stacking invisibly; `depth`
        // keeps the later start drawn on top of the one it insets from.
        .frame(width: max(columnWidth * slot.width - 2, 1), alignment: .topLeading)
        .offset(x: columnWidth * slot.offset, y: baseOffset + dragOffset)
        .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: isDragging ? 8 : 0)
        .zIndex(isDragging ? 100 : Double(slot.depth))
        // Tap opens the to-do; long press then drag reschedules it, so a plain
        // drag still scrolls the grid vertically. The tap is registered at high
        // priority because the long-press sequence otherwise claims the touch
        // down and a quick tap never resolves.
        .highPriorityGesture(TapGesture().onEnded {
            cursor.select(todo.uuid)
            selectedTodo = todo
        })
        // Simultaneous for the same reason as the grid's create gesture: an
        // exclusive drag here would stop the day scrolling whenever the finger
        // started on a block.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    guard case .second(_, let drag) = value else { return }
                    if draggingTodoID != todo.uuid {
                        draggingTodoID = todo.uuid
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    }
                    dragTranslation = drag?.translation.height ?? 0
                }
                .onEnded { _ in
                    reschedule(todo, on: day, by: dragTranslation)
                    draggingTodoID = nil
                    dragTranslation = 0
                }
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Move a to-do by however far it was dragged, snapped to a quarter hour.
    ///
    /// The move is clamped to the day rather than dropped when it would spill
    /// past midnight, so an overshoot lands at the edge instead of silently
    /// doing nothing.
    private func reschedule(_ todo: Todo, on day: Date, by translation: CGFloat) {
        guard let current = todo.assignedDate, translation != 0 else { return }

        let minutesMoved = Double(translation / hourHeight) * 60
        let snapped = (minutesMoved / 15).rounded() * 15
        guard snapped != 0,
              let moved = calendar.date(byAdding: .minute, value: Int(snapped), to: current)
        else { return }

        let dayStart = calendar.startOfDay(for: day)
        let duration = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        let lastStart = dayStart.addingTimeInterval(24 * 3600 - duration)
        let clamped = min(max(moved, dayStart), max(lastStart, dayStart))

        store.update(todo) {
            $0.assignedDate = clamped
            $0.assignedHasTime = true
        }

        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

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

        eventStore.loadEvents(
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
            .padding(.vertical, 3)
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
            return spaces.first { $0.uuid == id }?.name
        case .project(let id):
            return todos.first { $0.uuid == id }?.title
        default:
            return nil
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
