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

    @State private var scale: Scale = .day
    @State private var anchorDate = Date()
    @State private var eventStore = CalendarEventStore.shared

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

    /// Outside calendar events belong on the cross-cutting lists only.
    ///
    /// Today and This Week are "what does my day look like" views, where the
    /// user's meetings are the point. A space or project calendar is scoped to
    /// that container, so events from elsewhere would be noise.
    private var showsCalendarEvents: Bool {
        switch destination {
        case .today, .thisWeek, .anytime:
            settings.showCalendarEvents
        default:
            false
        }
    }

    /// To-dos this calendar lays out, narrowed to the container it was opened
    /// from.
    private var scopedTodos: [Todo] {
        switch destination {
        case .space(let id):
            // Everything filed in the space, including work inside its
            // projects, since the space calendar is about the whole area.
            todos.filter { $0.space?.uuid == id && !$0.isProject }
        case .project(let id):
            todos.filter { $0.parent?.uuid == id }
        default:
            todos
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pagedContent
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Reload whenever the visible range or the calendar preferences change.
        .task(id: eventReloadKey) { await reloadEvents() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Scale", selection: $scale) {
                    ForEach(Scale.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
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
            ForEach(pageRange, id: \.self) { offset in
                dayPage(for: offset)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pageIndex) { _, newValue in
            // Paging is the source of truth; the anchor follows it.
            anchorDate = date(forPage: newValue)
            recentreIfNeeded()
        }
        .onChange(of: anchorDate) { _, _ in
            // The Today button and the chevrons move the anchor directly, so
            // the page has to catch up without fighting the user's swipe.
            let target = page(for: anchorDate)
            if target != pageIndex { pageIndex = target }
        }
        .onChange(of: scale) { _, _ in
            // A page means a day in one scale and a week in the other, so the
            // index has to be recomputed against the date the user was on.
            pageOrigin = anchorDate
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
            timedGrid(for: days)
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

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Button("Today") { withAnimation(Theme.Animation.panel) { anchorDate = Date() } }
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

            // Day-of-week columns, so a week view reads at a glance.
            if scale == .week {
                HStack(spacing: 0) {
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
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: All-day

    /// Untimed scheduled todos, pinned above the grid as the spec requires.
    private func allDayRow(for days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, 6)

            HStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        ForEach(TodoQueries.untimed(scopedTodos, on: day, calendar: calendar, includeResolved: settings.showResolved)) { todo in
                            chip(for: todo)
                        }
                        ForEach(allDayEvents(on: day)) { event in
                            allDayEventChip(event)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
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
        InlineMarkdownText(markdown: todo.title.isEmpty ? "Untitled" : todo.title)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint(for: todo).opacity(0.2))
            }
            .contentShape(Rectangle())
            // Dragging an all-day chip onto the grid gives it a time. The grid
            // receives it via `dropDestination` below.
            .draggable(todo.uuid.uuidString) {
                Text(todo.title.isEmpty ? "Untitled" : todo.title)
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
            .onTapGesture { selectedTodo = todo }
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Timed grid

    private func timedGrid(for days: [Date]) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                hourLabels

                HStack(alignment: .top, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayColumn(for: day)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
        .frame(width: 52)
        .padding(.trailing, 6)
    }

    private func dayColumn(for day: Date) -> some View {
        let todosOnDay = TodoQueries.timed(
            scopedTodos, on: day, calendar: calendar, includeResolved: settings.showResolved
        )
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
        .overlay { creationStrips(for: day) }
        // Accepts all-day chips dragged down onto the grid, scheduling them
        // for the time they were dropped at.
        .dropDestination(for: String.self) { items, location in
            guard let identifier = items.first,
                  let uuid = UUID(uuidString: identifier),
                  let todo = todos.first(where: { $0.uuid == uuid })
            else { return false }

            schedule(todo, at: location.y, on: day)
            return true
        }
        .padding(.horizontal, 3)
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

        return VStack(spacing: 0) {
            ForEach(0..<slotCount, id: \.self) { index in
                let start = calendar.date(
                    byAdding: .minute,
                    value: index * Self.creationSlotMinutes,
                    to: calendar.startOfDay(for: day)
                ) ?? day

                // A press on an occupied slot belongs to the block there,
                // which has its own drag-to-move gesture, so that slot is left
                // transparent to touches.
                if isOccupied(at: start, on: day) {
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

    /// Whether a timed to-do already covers this moment.
    ///
    /// System events are ignored: they are read-only here, so creating a to-do
    /// alongside a meeting is a reasonable thing to want.
    private func isOccupied(at time: Date, on day: Date) -> Bool {
        TodoQueries.timed(
            scopedTodos, on: day, calendar: calendar, includeResolved: settings.showResolved
        ).contains { todo in
            guard let start = todo.assignedDate else { return false }
            let end = start.addingTimeInterval(
                todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
            )
            return time >= start && time < end
        }
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
        .highPriorityGesture(TapGesture().onEnded { selectedTodo = todo })
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
        let start = days.first ?? anchorDate
        let end = days.last ?? anchorDate
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
        days(forPage: page(for: anchorDate))
    }

    private func shift(by amount: Int) {
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear
        if let next = calendar.date(byAdding: component, value: amount, to: anchorDate) {
            withAnimation(Theme.Animation.panel) { anchorDate = next }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "" }
        return date.formatted(.dateTime.hour())
    }

    private var navigationTitle: String {
        switch scale {
        case .day:
            return anchorDate.formatted(.dateTime.weekday(.wide).month().day())
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return "Week" }
            let end = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
            return "\(week.start.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
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
