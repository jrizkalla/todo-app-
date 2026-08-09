import SwiftUI
import SwiftData

/// Compact cards shown under the AI summary.
///
/// These are read-only glances, not editors: the summary screen answers "what
/// does today look like", and anything that needs changing is a tap away in the
/// list or calendar. That is why they reuse the shared layout and query code
/// rather than the full `TodoRow`, whose focus handling and inline editing
/// would be dead weight here.

// MARK: Shared chrome

/// The rounded container every summary card sits in.
private struct SummaryCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        }
    }
}

// MARK: Weather

/// Today's high, low, and chance of rain, with the rest of the week beneath.
///
/// Driven by the same `WeatherForecast` the summary prompt is built from, so
/// the card and the generated text can never disagree.
struct WeatherSummaryCard: View {
    let forecast: WeatherForecast?

    var body: some View {
        SummaryCard(title: "Weather", symbol: symbol) {
            if let forecast, !forecast.daily.time.isEmpty {
                content(for: forecast.daily)
            } else {
                Text("Weather unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func content(for daily: WeatherForecast.DailyForecast) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(temperature(daily.temperatureMax[0]))
                    .font(.system(size: 34, weight: .medium, design: .rounded))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Low \(temperature(daily.temperatureMin[0]))")
                    if let chance = daily.precipitationProbabilityMax.first ?? nil, chance > 0 {
                        Label("\(chance)%", systemImage: "drop.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // The next few days, so "should I plan around the weather" is
            // answerable without leaving the summary.
            HStack(spacing: 0) {
                ForEach(upcoming(daily), id: \.offset) { day in
                    VStack(spacing: 3) {
                        Text(day.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: day.symbol)
                            .font(.caption)
                            .foregroundStyle(day.chance > 40 ? Color.accentColor : .secondary)
                        Text(temperature(day.high))
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Days after today, labelled by weekday.
    private func upcoming(_ daily: WeatherForecast.DailyForecast) -> [UpcomingDay] {
        let parser = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space)
            .year().month().day()

        return (1..<min(daily.time.count, 6)).map { index in
            let chance = daily.precipitationProbabilityMax[index] ?? 0
            let date = try? Date(daily.time[index], strategy: parser)

            return UpcomingDay(
                offset: index,
                label: date?.formatted(.dateTime.weekday(.abbreviated)) ?? daily.time[index],
                high: daily.temperatureMax[index],
                chance: chance,
                symbol: chance > 40 ? "cloud.rain.fill" : (chance > 15 ? "cloud.sun.fill" : "sun.max.fill")
            )
        }
    }

    private struct UpcomingDay {
        let offset: Int
        let label: String
        let high: Double
        let chance: Int
        let symbol: String
    }

    /// Today's chance of rain picks the icon, so the card reads at a glance.
    private var symbol: String {
        guard let chance = forecast?.daily.precipitationProbabilityMax.first ?? nil else {
            return "cloud.sun"
        }
        return chance > 40 ? "cloud.rain" : "cloud.sun"
    }

    private func temperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

// MARK: Inline calendar

/// A squeezed one-day calendar: the same blocks the full calendar draws, at a
/// fraction of the height.
///
/// Shares `CalendarLayout` with `CalendarView`, so overlapping work cascades
/// here exactly as it does there rather than drawing on top of itself.
struct InlineCalendarCard: View {
    let todos: [Todo]
    let events: [CalendarEvent]
    var day: Date = Date()
    var calendar: Calendar = .current
    var defaultDuration: TimeInterval

    /// Height of one hour. Much tighter than the full calendar's, since this is
    /// a glance rather than a surface to work on.
    private let hourHeight: CGFloat = 13

    var body: some View {
        SummaryCard(title: "Schedule", symbol: "calendar.day.timeline.left") {
            if timed.isEmpty && untimed.isEmpty {
                Text("Nothing scheduled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !untimed.isEmpty {
                        allDayRow
                    }
                    if !timed.isEmpty {
                        grid
                    }
                }
            }
        }
    }

    /// Untimed work, as chips above the grid — the same split the full calendar
    /// makes between the all-day header and the hour grid.
    private var allDayRow: some View {
        HStack(spacing: 4) {
            ForEach(untimed.prefix(3)) { todo in
                Text(todo.title.isEmpty ? "Untitled" : todo.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(todo.color.opacity(0.2))
                    }
            }
            if untimed.count > 3 {
                Text("+\(untimed.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The hour grid, cropped to the span that actually has something in it so
    /// an empty night does not dominate the card.
    private var grid: some View {
        let range = visibleHourRange
        let height = CGFloat(range.count) * hourHeight

        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(range, id: \.self) { hour in
                    Text(shortHour(hour))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(height: hourHeight, alignment: .top)
                }
            }
            .frame(width: 26)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(range, id: \.self) { _ in
                            Divider().frame(height: hourHeight, alignment: .top)
                        }
                    }

                    ForEach(blocks, id: \.id) { block in
                        block.view(
                            columnWidth: proxy.size.width,
                            hourHeight: hourHeight,
                            topHour: range.lowerBound
                        )
                    }
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    // MARK: Content

    private var timed: [Todo] {
        TodoQueries.timed(todos, on: day, calendar: calendar)
    }

    private var untimed: [Todo] {
        TodoQueries.untimed(todos, on: day, calendar: calendar)
    }

    private var timedEvents: [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { !$0.isAllDay && $0.start >= start && $0.start < end }
    }

    /// To-dos and events, positioned by the shared layout.
    private var blocks: [PositionedBlock] {
        var layout: [CalendarLayout.Block] = []

        for todo in timed {
            guard let start = todo.assignedDate else { continue }
            layout.append(
                .init(
                    id: "todo-\(todo.uuid.uuidString)",
                    start: start,
                    end: start.addingTimeInterval(todo.effectiveDuration(defaultDuration: defaultDuration))
                )
            )
        }
        for event in timedEvents {
            layout.append(.init(id: "event-\(event.id)", start: event.start, end: event.end))
        }

        let slots = CalendarLayout.slots(for: layout)

        var positioned: [PositionedBlock] = []
        for todo in timed {
            guard let start = todo.assignedDate else { continue }
            let id = "todo-\(todo.uuid.uuidString)"
            positioned.append(
                PositionedBlock(
                    id: id,
                    title: todo.title.isEmpty ? "Untitled" : todo.title,
                    start: start,
                    duration: todo.effectiveDuration(defaultDuration: defaultDuration),
                    color: todo.color,
                    slot: slots[id] ?? CalendarSlot(offset: 0, width: 1),
                    calendar: calendar
                )
            )
        }
        for event in timedEvents {
            let id = "event-\(event.id)"
            positioned.append(
                PositionedBlock(
                    id: id,
                    title: event.title,
                    start: event.start,
                    duration: event.duration,
                    color: Color(hex: event.colorHex),
                    slot: slots[id] ?? CalendarSlot(offset: 0, width: 1),
                    calendar: calendar
                )
            )
        }
        return positioned
    }

    /// Hours worth drawing: from the first block to the last, padded by one and
    /// never narrower than a few hours so the card keeps a stable shape.
    private var visibleHourRange: Range<Int> {
        let starts = blocks.map { calendar.component(.hour, from: $0.start) }
        let ends = blocks.map { block -> Int in
            let end = block.start.addingTimeInterval(block.duration)
            let hour = calendar.component(.hour, from: end)
            return calendar.component(.minute, from: end) > 0 ? hour + 1 : hour
        }

        guard let first = starts.min(), let last = ends.max() else { return 9..<18 }

        let lower = max(first - 1, 0)
        let upper = min(max(last + 1, lower + 4), 24)
        return lower..<upper
    }

    private func shortHour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "" }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))
    }

    /// One laid-out block, ready to draw.
    private struct PositionedBlock: Identifiable {
        let id: String
        let title: String
        let start: Date
        let duration: TimeInterval
        let color: Color
        let slot: CalendarSlot
        let calendar: Calendar

        func view(columnWidth: CGFloat, hourHeight: CGFloat, topHour: Int) -> some View {
            let minutes = CGFloat(calendar.component(.hour, from: start) * 60
                + calendar.component(.minute, from: start))
            let offset = (minutes - CGFloat(topHour * 60)) / 60 * hourHeight
            let height = max(CGFloat(duration / 3600) * hourHeight, 10)

            return Text(title)
                .font(.system(size: 9))
                .lineLimit(1)
                .padding(.horizontal, 3)
                .frame(
                    width: max(columnWidth * slot.width - 1, 1),
                    height: height,
                    alignment: .topLeading
                )
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.22))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(color).frame(width: 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .offset(x: columnWidth * slot.offset, y: offset)
                .zIndex(Double(slot.depth))
        }
    }
}

// MARK: To-do list

/// Today's unfinished work, with working checkboxes.
///
/// Interactive on purpose: ticking something off is the one action worth having
/// here, and it is the same `TodoCheckbox` and `TodoStore.toggle` the real list
/// uses, so behavior cannot drift.
struct TodoListCard: View {
    let todos: [Todo]
    var limit: Int = 5

    @Environment(\.modelContext) private var context

    private var store: TodoStore { TodoStore(context: context) }

    private var items: [Todo] {
        Array(TodoQueries.today(todos).prefix(limit))
    }

    private var remaining: Int {
        max(TodoQueries.today(todos).count - limit, 0)
    }

    var body: some View {
        SummaryCard(title: "Today", symbol: "checklist") {
            if items.isEmpty {
                Text("Nothing due today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items) { todo in
                        row(for: todo)
                    }

                    if remaining > 0 {
                        Text("+\(remaining) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(for todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.rowSpacing) {
            TodoCheckbox(
                state: todo.state,
                tint: todo.color,
                onToggle: { withAnimation(Theme.Animation.toggle) { _ = store.toggle(todo) } },
                onSelect: { _ = store.setState(todo, to: $0) }
            )
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            InlineMarkdownText(
                markdown: todo.title.isEmpty ? "Untitled" : todo.title,
                strikethrough: todo.state == .completed
            )
            .font(.callout)
            .foregroundStyle(todo.state.isResolved ? .secondary : .primary)

            Spacer(minLength: 0)

            if let assigned = todo.assignedDate, todo.assignedHasTime {
                Text(assigned.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("Summary cards") {
    ScrollView {
        VStack(spacing: 14) {
            WeatherSummaryCard(forecast: nil)
            InlineCalendarCard(todos: [], events: [], defaultDuration: 15 * 60)
            TodoListCard(todos: [])
        }
        .padding()
    }
    .previewEnvironment()
}
#endif
