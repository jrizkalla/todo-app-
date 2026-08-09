import AppIntents
import SwiftData
import SwiftUI
import WidgetKit

/// Home screen widget listing today's unfinished work.
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
        .description("Your unfinished to-dos for today.")
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
            .init(id: UUID(), title: "Water the plants", time: nil, colorHex: nil),
            .init(id: UUID(), title: "Stand-up", time: "9:00 AM", colorHex: nil),
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
                time: todo.assignedHasTime
                    ? todo.assignedDate?.formatted(date: .omitted, time: .shortened)
                    : nil,
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
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(entry.items.prefix(visibleCount)) { item in
                        TodayWidgetRow(item: item, showsTime: family != .systemSmall)
                    }
                }

                if remaining > 0 {
                    Text("+\(remaining) more")
                        .font(.caption2)
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

    private var header: some View {
        HStack {
            Label("Today", systemImage: "star.fill")
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
/// complete the to-do in place instead of launching the app.
private struct TodayWidgetRow: View {
    let item: TodoSnapshot
    let showsTime: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(intent: CompleteTodoIntent(todoID: item.id.uuidString)) {
                Image(systemName: "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(item.title)")

            Text(item.title)
                .font(.caption)
                .lineLimit(1)

            if showsTime, let time = item.time {
                Spacer(minLength: 4)
                Text(time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
