import SwiftUI
import SwiftData

/// Compact cards shown under the AI summary.
///
/// These are glances, not editors: the summary screen answers "what does today
/// look like", and anything that needs changing is a tap away in the list or
/// calendar. That is why they reuse the shared layout and query code rather
/// than the full `TodoRow`, whose focus handling and inline editing would be
/// dead weight here.
///
/// The cards float on the summary's background image, so every one of them is
/// a glass panel — text is never drawn straight onto the photo, where a light
/// patch in the image would swallow it.

// MARK: Shared chrome

/// The glass container every summary card sits in.
///
/// `glassEffect` on iOS 26 and up; the material fallback below keeps earlier
/// systems (and macOS builds without the API) looking like the same design
/// rather than reverting to the flat gray box this replaced.
struct SummaryCard<Content: View>: View {
    let title: String
    let symbol: String
    /// Set when tapping the card goes somewhere, which adds a chevron and the
    /// button treatment.
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        if let action {
            Button(action: action) { panel }
                .buttonStyle(PressableCardStyle())
                .accessibilityAddTraits(.isButton)
        } else {
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        // The cards sit on a darkened image, so their contents are drawn light
        // throughout rather than following the system's light/dark text color.
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

/// The press response every tappable card and the create button share.
///
/// A plain `Button` on a custom label gives no feedback at all, which on a
/// large glass panel leaves the user unsure the tap registered. A small, fast
/// scale is enough — and having one style rather than a per-site `scaleEffect`
/// is what keeps the feedback identical everywhere.
struct PressableCardStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Animation.quick, value: configuration.isPressed)
    }
}

extension View {
    /// Liquid glass, with a material fallback for platforms without it.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            }
            .clipShape(shape)
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
                    .foregroundStyle(.white.opacity(0.7))
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
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            }

            // The next few days, so "should I plan around the weather" is
            // answerable without leaving the summary.
            HStack(spacing: 0) {
                ForEach(upcoming(daily), id: \.offset) { day in
                    VStack(spacing: 3) {
                        Text(day.label)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                        Image(systemName: day.symbol)
                            .font(.caption)
                            .foregroundStyle(day.chance > 40 ? .white : .white.opacity(0.75))
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

/// The next couple of hours, drawn as a miniature calendar.
///
/// Scoped to a short window rather than the whole day on purpose: this card
/// answers "what is coming up", so an empty morning or a finished evening is
/// wasted height. When nothing falls in the next two hours the window skips
/// ahead to the first stretch that has something in it, and when nothing is left
/// today the card draws nothing at all and lets the summary drop it.
///
/// Untimed work is left out entirely — the Any Time card below is where that
/// belongs — and what remains is the same block layout `CalendarView` draws,
/// sharing `CalendarLayout` so overlapping work cascades here exactly as it does
/// there.
struct InlineCalendarCard: View {
    let todos: [Todo]
    let events: [CalendarEvent]
    var day: Date = Date()
    var calendar: Calendar = .current
    var defaultDuration: TimeInterval
    /// Tapping the card opens the full calendar on this day.
    var onOpen: (() -> Void)?

    /// Height of one hour. Much taller than the old whole-day version, since
    /// only a short window is on screen.
    private let hourHeight: CGFloat = 46

    /// How far ahead the window looks.
    private let lookahead: TimeInterval = 2 * 3600
    /// How much of the recent past stays visible, so something that started a
    /// few minutes ago is still in view.
    private let lookbehind: TimeInterval = 30 * 60

    /// "Now", redrawn every minute so the window and its marker creep forward
    /// rather than freezing wherever they were when the card first appeared.
    ///
    /// A `TimelineView` rather than a `Timer` publisher: it schedules itself
    /// against the run loop, and stops while the view is off screen.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    /// Whether this card would draw anything at `now`, for callers deciding
    /// whether to place it at all. Runs the same `Window` the card draws from,
    /// so a caller cannot disagree with the card about whether it is empty.
    ///
    /// `now` is required rather than defaulted: the caller is already inside a
    /// `TimelineView` and must ask about the same instant it is drawing, not
    /// about whenever this happens to be evaluated.
    func hasContent(now: Date) -> Bool {
        !Window(card: self, now: now).blocks.isEmpty
    }

    /// Everything the card draws, worked out once per redraw.
    ///
    /// `TodoQueries.timed` walks every to-do, so the window, its hours, and its
    /// blocks are resolved together and passed down rather than recomputed by
    /// each part of the view that happens to need them.
    @ViewBuilder
    private func content(now: Date) -> some View {
        let window = Window(card: self, now: now)

        // Nothing timed left today means no grid worth drawing — an empty card
        // is just a labelled void taking up a screenful of height. The summary
        // drops the card entirely instead. See `AISummaryView`.
        if !window.blocks.isEmpty {
            SummaryCard(title: "Schedule", symbol: "calendar.day.timeline.left", action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    // A window that skipped ahead looks exactly like the live
                    // one, so say which it is rather than making the user read
                    // the hour gutter to find out.
                    if window.isAhead, let first = window.blocks.map(\.start).min() {
                        Text("Next up · \(first.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    grid(window: window, now: now)
                }
            }
        }
    }

    /// The hour grid for the window, with the current-time marker on top.
    private func grid(window: Window, now: Date) -> some View {
        let hours = window.hours
        let height = CGFloat(hours.count) * hourHeight
        let windowStart = window.start

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(hours, id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(height: hourHeight, alignment: .top)
                }
            }
            .frame(width: 46)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(hours, id: \.self) { _ in
                            Rectangle()
                                .fill(.white.opacity(0.18))
                                .frame(height: 0.5)
                                .frame(height: hourHeight, alignment: .top)
                        }
                    }

                    ForEach(window.blocks, id: \.id) { block in
                        block.view(
                            columnWidth: proxy.size.width,
                            hourHeight: hourHeight,
                            windowStart: windowStart
                        )
                    }

                    // Only when now is actually on this grid. On a jumped-ahead
                    // window the line would sit above the first hour — reading
                    // as "this is starting now" for something hours away.
                    if !window.isAhead {
                        currentTimeIndicator(now: now, windowStart: windowStart)
                    }
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    /// The same red line and dot the full calendar draws, so the two surfaces
    /// read as one calendar at two sizes.
    @ViewBuilder
    private func currentTimeIndicator(now: Date, windowStart: Date) -> some View {
        let offset = CGFloat(now.timeIntervalSince(windowStart) / 3600) * hourHeight

        Rectangle()
            .fill(Color.red)
            .frame(height: 1.5)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: -3.5)
            }
            .offset(y: offset)
            .zIndex(10)
    }

    // MARK: Window

    /// The card's contents for one moment: where the window starts, which hours
    /// it covers, and the blocks laid out inside it.
    ///
    /// Resolved once per redraw and handed down. Working these out separately
    /// meant `TodoQueries.timed` — which walks every to-do in the store — ran
    /// three or four times for a single frame.
    struct Window {
        let start: Date
        let hours: [Date]
        let blocks: [PositionedBlock]
        /// True when the window had to skip ahead past an empty stretch to find
        /// something. The card uses this to label itself and to drop the "now"
        /// marker, which no longer falls inside the hours on screen.
        let isAhead: Bool

        init(card: InlineCalendarCard, now: Date) {
            let calendar = card.calendar
            let live = calendar.startOfHour(for: now.addingTimeInterval(-card.lookbehind))

            // Every timed item on the day, not just the ones near now: an empty
            // live window has to look further out for the next thing scheduled.
            // Untimed work is deliberately absent — it has no place on an hour
            // grid, and the Any Time card already lists it.
            var all: [(id: String, title: String, start: Date, duration: TimeInterval, color: Color)] = []

            for todo in TodoQueries.timed(card.todos, on: card.day, calendar: calendar) {
                guard let todoStart = todo.assignedDate else { continue }
                let duration = todo.effectiveDuration(defaultDuration: card.defaultDuration)

                all.append((
                    id: "todo-\(todo.uuid.uuidString)",
                    title: todo.title.isEmpty ? "Untitled" : todo.title,
                    start: todoStart,
                    duration: duration,
                    color: todo.color
                ))
            }

            for event in card.events where !event.isAllDay {
                all.append((
                    id: "event-\(event.id)",
                    title: event.title,
                    start: event.start,
                    duration: event.duration,
                    color: Color(hex: event.colorHex)
                ))
            }

            // The window the card would draw if something is coming up right
            // now; otherwise the first two-hour stretch that has anything in it.
            let span = Double(max(Int(card.lookahead / 3600) + 2, 3)) * 3600
            func overlapping(_ windowStart: Date) -> [(id: String, title: String, start: Date, duration: TimeInterval, color: Color)] {
                let end = windowStart.addingTimeInterval(span)
                return all.filter { $0.start < end && $0.start.addingTimeInterval($0.duration) > windowStart }
            }

            var candidates = overlapping(live)
            if candidates.isEmpty,
               // Only work still ahead of us: something that ended this morning
               // is not "next up".
               let next = all
                   .filter({ $0.start.addingTimeInterval($0.duration) > now })
                   .min(by: { $0.start < $1.start }) {
                // Anchor on the hour containing the next block so it sits near
                // the top of the grid rather than wherever the clock happens to
                // fall, and so the hour labels stay whole hours.
                let anchor = calendar.startOfHour(for: next.start)
                candidates = overlapping(anchor)
                self.start = anchor
                self.isAhead = true
            } else {
                self.start = live
                self.isAhead = false
            }

            let start = self.start
            let slots = CalendarLayout.slots(
                for: candidates.map {
                    .init(id: $0.id, start: $0.start, end: $0.start.addingTimeInterval($0.duration))
                }
            )
            self.blocks = candidates.map { candidate in
                PositionedBlock(
                    id: candidate.id,
                    title: candidate.title,
                    start: candidate.start,
                    duration: candidate.duration,
                    color: candidate.color,
                    slot: slots[candidate.id] ?? CalendarSlot(offset: 0, width: 1)
                )
            }

            // Hours the grid draws: the default window, stretched to cover a
            // block running past it so a long meeting is not silently clipped,
            // and never past midnight. At least three, so the card keeps a
            // stable shape whether or not anything is scheduled.
            //
            // Measured from the window's own start rather than from `now` — a
            // jumped-ahead window that still sized itself against the clock
            // would grow an hour taller for every hour of empty day it skipped.
            let minimumEnd = calendar
                .startOfHour(for: start.addingTimeInterval(card.lookahead))
                .addingTimeInterval(3600)
            let latest = self.blocks
                .map { $0.start.addingTimeInterval($0.duration) }
                .max() ?? minimumEnd
            let gridEnd = min(
                max(minimumEnd, calendar.startOfHour(for: latest).addingTimeInterval(3600)),
                calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
            )

            let count = max(Int(gridEnd.timeIntervalSince(start) / 3600), 3)
            self.hours = (0..<count).compactMap {
                calendar.date(byAdding: .hour, value: $0, to: start)
            }
        }
    }

    /// Hour labels carry am/pm, since a window that straddles noon or midnight
    /// is ambiguous without it.
    private func hourLabel(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    /// One laid-out block, ready to draw.
    struct PositionedBlock: Identifiable {
        let id: String
        let title: String
        let start: Date
        let duration: TimeInterval
        let color: Color
        let slot: CalendarSlot

        func view(columnWidth: CGFloat, hourHeight: CGFloat, windowStart: Date) -> some View {
            let offset = CGFloat(start.timeIntervalSince(windowStart) / 3600) * hourHeight
            let height = max(CGFloat(duration / 3600) * hourHeight, 16)

            return VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(height > 30 ? 2 : 1)
                if height > 34 {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9))
                        .opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(
                width: max(columnWidth * slot.width - 2, 1),
                height: height,
                alignment: .topLeading
            )
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.55))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(color).frame(width: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .offset(x: columnWidth * slot.offset, y: offset)
            .zIndex(Double(slot.depth))
        }
    }
}

private extension Calendar {
    /// Top of the hour containing `date`.
    func startOfHour(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }
}

// MARK: Any Time

/// Today's unfinished work that has no time attached.
///
/// Timed work is the schedule card's job, so listing it again here would show
/// the same to-do twice on one screen. What is left is precisely the work the
/// user can slot in whenever — hence "Any Time".
///
/// Interactive on purpose: ticking something off is the one action worth having
/// here, and it is the same `TodoCheckbox` and `TodoStore.toggle` the real list
/// uses, so behavior cannot drift.
struct TodoListCard: View {
    let todos: [Todo]
    var limit: Int = 5
    /// Tapping the card opens the Today list.
    var onOpen: (() -> Void)?

    @Environment(\.modelContext) private var context

    private var store: TodoStore { TodoStore(context: context) }

    /// Whether this card would draw anything, for callers deciding whether to
    /// place it at all. Same query the card itself runs, so a caller cannot end
    /// up disagreeing with the card about whether it is empty.
    static func hasContent(todos: [Todo]) -> Bool {
        !TodoQueries.untimedToday(todos).isEmpty
    }

    /// Today's work with no time of day. See `TodoQueries.untimedToday`.
    private var allItems: [Todo] {
        TodoQueries.untimedToday(todos)
    }

    private var items: [Todo] {
        Array(allItems.prefix(limit))
    }

    private var remaining: Int {
        max(allItems.count - limit, 0)
    }

    @ViewBuilder
    var body: some View {
        // An empty list means no card: "Nothing to do" on its own panel is a
        // whole card spent saying there is nothing to show. The summary drops it
        // and, if the schedule went too, says so once. See `AISummaryView`.
        if !items.isEmpty {
            SummaryCard(title: "Any Time", symbol: "checklist", action: onOpen) {
                VStack(alignment: .leading, spacing: scale.rowGap) {
                    ForEach(items) { todo in
                        row(for: todo)
                    }

                    if remaining > 0 {
                        Text("+\(remaining) more")
                            .font(scale.overflowFont)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            // Ticking something off here removes its row and shrinks the card;
            // the same curve the real list uses for the same change. Ticking the
            // last one removes the card itself, which the summary animates.
            .animation(Theme.Animation.listChange, value: items.map(\.uuid))
        }
    }

    /// Sizes and fonts for this surface. See `Theme.RowScale`.
    private let scale = Theme.RowScale.compact

    private func row(for todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.horizontalSpacing) {
            TodoCheckbox(
                state: todo.state,
                tint: .white,
                onToggle: { withAnimation(Theme.Animation.toggle) { _ = store.toggle(todo) } },
                onSelect: { _ = store.setState(todo, to: $0) },
                scale: scale
            )
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            InlineMarkdownText(
                markdown: todo.title.isEmpty ? "Untitled" : todo.title,
                strikethrough: todo.state == .completed
            )
            .font(scale.titleFont)
            .foregroundStyle(todo.state.isResolved ? .white.opacity(0.6) : .white)

            Spacer(minLength: 0)
        }
        // The checkbox is the only control here; a tap anywhere else should
        // fall through to the card's own "open the list" action.
        .contentShape(Rectangle())
    }
}

// MARK: All clear

/// Shown in place of the schedule and Any Time cards when today holds neither.
///
/// One card rather than two empty ones: two panels each saying "nothing" reads
/// as a broken screen, while a single deliberate one reads as an answer. It is
/// not tappable — there is nothing on the other side of it.
struct AllClearCard: View {
    var body: some View {
        VStack(spacing: 10) {
            graphic

            Text("All clear")
                .font(.title3.weight(.semibold))

            Text("Nothing scheduled, nothing waiting.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .glassCard()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All clear. Nothing scheduled, nothing waiting.")
    }

    /// A checkmark inside two haloes.
    ///
    /// Drawn from shapes rather than shipped as an asset so it picks up the
    /// card's white-on-photo treatment automatically, and so it stays crisp at
    /// any size. The haloes are what keep it from reading as one more checkbox
    /// on a screen already full of them.
    private var graphic: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 74, height: 74)

            Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1)
                .frame(width: 56, height: 56)

            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        // Decorative: the text below already carries the meaning.
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Summary cards") {
    ZStack {
        SummaryBackgroundView(background: .dawn)

        ScrollView {
            VStack(spacing: 14) {
                WeatherSummaryCard(forecast: nil)
                InlineCalendarCard(todos: [], events: [], defaultDuration: 15 * 60)
                TodoListCard(todos: [])
                AllClearCard()
            }
            .padding()
        }
    }
    .previewEnvironment()
}
#endif
