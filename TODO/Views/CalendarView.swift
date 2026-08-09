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
    /// Where a long press landed, cleared when the press ends.
    @State private var pendingCreationPoint: CGPoint?

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
        Button {
            selectedTodo = todo
        } label: {
            InlineMarkdownText(markdown: todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint(for: todo).opacity(0.2))
                }
        }
        .buttonStyle(.plain)
        // Dragging an all-day chip onto the grid gives it a time. The grid
        // receives it via `dropDestination` below.
        .draggable(todo.uuid.uuidString) {
            Text(todo.title.isEmpty ? "Untitled" : todo.title)
                .font(.caption)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
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

        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Hour grid lines.
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
                        columnWidth: proxy.size.width
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
                        columnWidth: proxy.size.width
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Long-pressing empty space creates a to-do at that time, the way
            // Calendar.app creates an event.
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45) {
            } onPressingChanged: { pressing in
                if !pressing { pendingCreationPoint = nil }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        guard case .second(_, let drag?) = value else { return }
                        createTodo(at: drag.location.y, on: day)
                    }
            )
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
        }
        .frame(height: hourHeight * 24)
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

    /// Create a to-do at the pressed time and open it for editing.
    private func createTodo(at y: CGFloat, on day: Date) {
        let start = time(atY: y, on: day)

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

        return Button {
            selectedTodo = todo
        } label: {
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
        }
        .buttonStyle(.plain)
        // Overlapping blocks share the column instead of stacking.
        .frame(width: max(columnWidth * slot.width - 2, 1), alignment: .topLeading)
        .offset(x: columnWidth * slot.offset, y: baseOffset + dragOffset)
        .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: isDragging ? 8 : 0)
        .zIndex(isDragging ? 1 : 0)
        // Long press then drag reschedules, so a plain drag still scrolls the
        // grid vertically.
        .gesture(
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
    }

    /// Move a to-do by however far it was dragged, snapped to a quarter hour.
    private func reschedule(_ todo: Todo, on day: Date, by translation: CGFloat) {
        guard let current = todo.assignedDate, translation != 0 else { return }

        let minutesMoved = Double(translation / hourHeight) * 60
        let snapped = (minutesMoved / 15).rounded() * 15
        guard snapped != 0 else { return }

        guard let moved = calendar.date(byAdding: .minute, value: Int(snapped), to: current),
              calendar.isDate(moved, inSameDayAs: day)
        else { return }

        store.update(todo) {
            $0.assignedDate = moved
            $0.assignedHasTime = true
        }
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
    private func blockHeight(for todo: Todo) -> CGFloat {
        let seconds = todo.effectiveDuration(defaultDuration: settings.defaultEventDuration)
        return max(CGFloat(seconds / 3600) * hourHeight, 18)
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
