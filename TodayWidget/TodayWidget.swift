import AppIntents
import SwiftData
import SwiftUI
import WidgetKit

/// Home screen widget listing today's unfinished work.
///
/// Shows the whole Today list, timed work included — unlike the summary's "Any
/// Time" card, which sits next to a schedule grid that already draws the timed
/// items. On the home screen there is no such neighbor, so leaving timed work
/// out would just hide part of the day.
///
/// Reads the app's SwiftData store directly out of the shared app group rather
/// than caching a snapshot in `UserDefaults`, so the widget can never show a
/// list the app has already moved on from. Completing an item goes through the
/// same `Todo.setState` the app calls, which is why a tick here survives the
/// next launch instead of being undone by it.
struct TodayWidget: Widget {
    static let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayTimelineProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Everything on today's list, including timed work.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: Timeline

struct TodayEntry: TimelineEntry {
    let date: Date
    let items: [TodoSnapshot]
    /// Items beyond the ones that fit, so the widget can say "+3 more".
    let overflow: Int
    /// Set when the shared store could not be opened, which is the one failure
    /// the user can act on (the app has not been launched yet, or the App Group
    /// capability is missing from the build).
    let isUnavailable: Bool

    static let placeholder = TodayEntry(
        date: .now,
        items: [
            .init(id: UUID(), title: "Standup", time: "9:30 AM", colorHex: nil),
            .init(id: UUID(), title: "Water the plants", time: nil, colorHex: nil),
            .init(id: UUID(), title: "Reply to Sam", time: nil, colorHex: nil),
            .init(id: UUID(), title: "Renew the lease", time: nil, colorHex: nil),
        ],
        overflow: 0,
        isUnavailable: false
    )
}

/// A to-do flattened for display.
///
/// The widget renders this rather than the `@Model` itself so the view never
/// touches a managed object off the main actor, and so the timeline entry stays
/// a plain value.
struct TodoSnapshot: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// Formatted time of day, or `nil` for work not pinned to one. Preformatted
    /// here because the entry has to stay a plain value, and because the
    /// provider is the last place that still holds the `Date`.
    let time: String?
    let colorHex: String?
}

struct TodayTimelineProvider: TimelineProvider {
    /// Most rows the largest family can show.
    private static let maxItems = 8

    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = loadEntry()

        // Refresh at the next midnight, when "today" changes and the list is
        // wrong by definition. Edits in the app reload the widget explicitly,
        // so there is nothing to gain from polling in between.
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 3600))

        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }

    /// Read today's unfinished work from the shared store.
    ///
    /// The full Today list, timed items included — `TodoQueries.today` is the
    /// same rule the app's Today destination uses, so the widget and the list it
    /// stands in for can never disagree about what counts as today.
    @MainActor
    private func loadEntry() -> TodayEntry {
        guard let container = try? ModelContainer.widgetContainer() else {
            return TodayEntry(date: .now, items: [], overflow: 0, isUnavailable: true)
        }

        let todos = (try? container.mainContext.fetch(FetchDescriptor<Todo>())) ?? []
        let today = TodoQueries.today(todos)

        let snapshots = today.prefix(Self.maxItems).map { todo in
            TodoSnapshot(
                id: todo.uuid,
                title: todo.title.isEmpty ? "Untitled" : todo.title,
                time: Self.timeLabel(for: todo),
                colorHex: todo.resolvedColorHex
            )
        }

        return TodayEntry(
            date: .now,
            items: Array(snapshots),
            overflow: max(today.count - Self.maxItems, 0),
            isUnavailable: false
        )
    }

    /// The time of day an item is pinned to, or `nil` for untimed work.
    ///
    /// Only `assignedHasTime` items get a label: a due date without a time says
    /// nothing about when in the day to act, and stamping midnight on it would
    /// invent a schedule the user never set.
    private static func timeLabel(for todo: Todo) -> String? {
        guard todo.assignedHasTime, let assigned = todo.assignedDate else { return nil }
        return assigned.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: View

struct TodayWidgetView: View {
    let entry: TodayEntry

    @Environment(\.widgetFamily) private var family

    /// How many rows fit in the current family.
    private var visibleCount: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 8
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if entry.isUnavailable {
                Text("Open TODO to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.items.isEmpty {
                Spacer(minLength: 0)
                Label("All clear", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: Theme.RowScale.widget.rowGap) {
                    ForEach(entry.items.prefix(visibleCount)) { item in
                        // The small family drops the times: its rows are about
                        // 123pt wide, so a title of any ordinary length plus a
                        // time truncates the title. Which item it is matters
                        // more there than when it is due.
                        TodayWidgetRow(item: item, showsTime: family != .systemSmall)
                    }
                }

                if remaining > 0 {
                    Text("+\(remaining) more")
                        .font(Theme.RowScale.widget.overflowFont)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Items that did not fit here, plus any the provider already trimmed.
    private var remaining: Int {
        max(entry.items.count - visibleCount, 0) + entry.overflow
    }

    /// Titled to match the app's Today destination, star and all — the widget is
    /// that list on the home screen, so it carries the same name and symbol as
    /// `ListDestination.today` rather than one of its own.
    private var header: some View {
        HStack {
            Label("Today", systemImage: "star")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            Spacer()

            if !entry.items.isEmpty {
                Text("\(entry.items.count + entry.overflow)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One row: a tappable checkbox and the title.
///
/// The checkbox is a `Button` wrapping an `AppIntent`, which is what lets it
/// complete the to-do in place instead of launching the app. It draws
/// `TodoCheckboxShape` — the same box the app's list and summary card use — so
/// the widget reads as the same list rather than a lookalike. Sizes and gaps
/// come from `Theme.RowScale.widget`.
private struct TodayWidgetRow: View {
    let item: TodoSnapshot
    let showsTime: Bool

    private let scale = Theme.RowScale.widget

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.horizontalSpacing) {
            Button(intent: CompleteTodoIntent(todoID: item.id.uuidString)) {
                // Widget rows only ever list unfinished work, so the box is
                // always drawn open — ticking it removes the row.
                TodoCheckboxShape(state: .open, tint: tint, scale: scale)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(item.title)")
            // Match the baseline nudge the app's rows use, so the box sits on
            // the title's optical baseline rather than its text box.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            Text(item.title)
                .font(scale.titleFont)
                .lineLimit(1)

            if showsTime, let time = item.time {
                Spacer(minLength: 4)
                Text(time)
                    .font(scale.metadataFont)
                    .foregroundStyle(.secondary)
                    // A time is short and fixed-width; the title is neither. Let
                    // the title take the truncation so the time never arrives
                    // half-drawn ("9:3…"), which would read as a wrong time
                    // rather than a shortened one.
                    .layoutPriority(1)
            }
        }
    }

    private var tint: Color {
        item.colorHex.map { Color(hex: $0) } ?? .accentColor
    }
}

#if DEBUG
#Preview("Today", as: .systemMedium) {
    TodayWidget()
} timeline: {
    TodayEntry.placeholder
    TodayEntry(date: .now, items: [], overflow: 0, isUnavailable: false)
}
#endif
