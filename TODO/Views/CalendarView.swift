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

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query private var todos: [Todo]

    @State private var scale: Scale = .day
    @State private var anchorDate = Date()
    @State private var eventStore = CalendarEventStore.shared

    /// Height of one hour in the grid.
    private let hourHeight: CGFloat = 52

    private var calendar: Calendar { settings.calendar }
    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            allDayRow
            Divider()
            timedGrid
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
    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, 6)

            HStack(alignment: .top, spacing: 0) {
                ForEach(visibleDays, id: \.self) { day in
                    VStack(spacing: 4) {
                        ForEach(TodoQueries.untimed(todos, on: day, calendar: calendar)) { todo in
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
    }

    // MARK: Timed grid

    private var timedGrid: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                hourLabels

                HStack(alignment: .top, spacing: 0) {
                    ForEach(visibleDays, id: \.self) { day in
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
        ZStack(alignment: .topLeading) {
            // Hour grid lines.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Divider().frame(height: hourHeight, alignment: .top)
                }
            }

            // System events sit behind to-dos, since to-dos are the app's
            // own content and stay tappable.
            ForEach(timedEvents(on: day)) { event in
                eventBlock(for: event, on: day)
            }

            if calendar.isDateInToday(day) {
                currentTimeIndicator
            }

            ForEach(TodoQueries.timed(todos, on: day, calendar: calendar)) { todo in
                eventBlock(for: todo, on: day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 3)
    }

    private func eventBlock(for todo: Todo, on day: Date) -> some View {
        let offset = verticalOffset(for: todo, on: day)
        let height = blockHeight(for: todo)

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
                    .fill(tint(for: todo).opacity(0.22))
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
        .offset(y: offset)
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
        return "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(settings.showCalendarEvents)-\(settings.visibleCalendars.joined(separator: ","))"
    }

    private func reloadEvents() async {
        guard settings.showCalendarEvents else {
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
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        return eventStore.events.filter { event in
            // An all-day event can span days, so overlap is the right test.
            event.isAllDay && event.start < dayEnd && event.end > dayStart
        }
    }

    /// Timed system events starting on a given day.
    private func timedEvents(on day: Date) -> [CalendarEvent] {
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
    private func eventBlock(for event: CalendarEvent, on day: Date) -> some View {
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
        .offset(y: minutes / 60 * hourHeight)
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

    private var visibleDays: [Date] {
        switch scale {
        case .day:
            return [calendar.startOfDay(for: anchorDate)]
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else {
                return [calendar.startOfDay(for: anchorDate)]
            }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
        }
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
