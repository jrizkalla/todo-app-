import SwiftData
import SwiftUI
import WidgetKit

/// How much of today is done, as a ring.
///
/// The counterpart to `TodayWidget`: that one lists the work, this one measures
/// it. A list answers "what is there?", which needs room for several rows; a
/// fraction answers "how far in am I?", which needs almost none — so this is
/// the one that earns a small slot.
///
/// The medium family adds the single most useful row the extra width can hold:
/// the next thing to do. Not the *first few* things — four short rows is what
/// `TodayWidget` at medium already is, and a second widget that is a worse copy
/// of the first is not worth a home screen slot. One task, named clearly, is
/// what this widget adds to the ring.
struct ProgressWidget: Widget {
    static let kind = "TodayProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlanceTimelineProvider()) { entry in
            ProgressWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Progress")
        .description("How much of today is done, and what's next.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Timeline

struct GlanceTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(context.isPreview ? .placeholder : GlanceEntry.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let entry = GlanceEntry.load(now: now)
        completion(
            Timeline(entries: [entry], policy: .after(GlanceEntry.nextRefresh(after: now)))
        )
    }
}

// MARK: View

struct ProgressWidgetView: View {
    let entry: GlanceEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.isUnavailable {
            unavailable
        } else if family == .systemMedium {
            medium
        } else {
            small
        }
    }

    /// Small: the ring, and the word for what it is.
    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                ProgressRing(entry: entry, diameter: 74)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Medium: the header across the top, then the ring beside the next task.
    ///
    /// The header spans the width rather than sitting in the ring's column,
    /// because it names the whole widget and not the ring alone. Below it the
    /// two halves are centred against each other, so the ring and the title sit
    /// on one optical line instead of the ring hanging below a block of text.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(spacing: 14) {
                ProgressRing(entry: entry, diameter: 62)

                VStack(alignment: .leading, spacing: 3) {
                    if let next = entry.next {
                        Text(nextLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(next.title)
                            .font(.callout.weight(.medium))
                            // Two lines, because this is the one title the
                            // widget shows: truncating it to fit a column that
                            // has room to spare would hide the very thing the
                            // row is for.
                            .lineLimit(2)

                        if let time = next.time {
                            Text(time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(caption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Takes the slack left under the header, so the pair sits centred in
            // it rather than pinned to the top with a gap below.
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            Text("Open TODO to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Named and marked like the app's Today destination, as `TodayWidget` is —
    /// both stand in for the same list, so both carry its name and star.
    private var header: some View {
        Label("Today", systemImage: "star")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
    }

    /// Whether the named task is the day's next appointment or simply the next
    /// thing to pick up.
    ///
    /// Worth distinguishing: "Next" beside an untimed task would imply a slot
    /// it does not have, and the user would go looking for a time that is not
    /// there.
    private var nextLabel: String {
        entry.next?.time == nil ? "Up next" : "Next"
    }

    /// What the ring means in words, for the cases a fraction cannot say.
    private var caption: String {
        if entry.isEmpty { return "Nothing scheduled" }
        if entry.isComplete { return "All done" }
        return "\(entry.remaining) to go"
    }
}

/// The ring, with the count inside it.
///
/// Drawn rather than taken from `Gauge` or `ProgressView` because the inside of
/// the ring is the most valuable space in the widget — at small size it is the
/// only place the actual numbers fit — and the stock styles fill it with their
/// own label.
private struct ProgressRing: View {
    let entry: GlanceEntry
    let diameter: CGFloat

    /// Proportioned to the ring so it reads the same at both sizes rather than
    /// turning into a hairline in the small family and a band in the medium.
    private var lineWidth: CGFloat { diameter * 0.12 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.2), lineWidth: lineWidth)

            // An empty day draws no arc at all. A zero-length arc on a full
            // track reads as "none of a lot done", which is the opposite of
            // what an empty day means.
            if !entry.isEmpty {
                Circle()
                    .trim(from: 0, to: entry.fraction)
                    .stroke(
                        .tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    // From the top, clockwise — the direction a clock face and
                    // every other progress ring on the device already run.
                    .rotationEffect(.degrees(-90))
            }

            label
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Today's progress")
        .accessibilityValue(
            entry.isEmpty ? "Nothing scheduled" : "\(entry.done) of \(entry.total) done"
        )
    }

    @ViewBuilder
    private var label: some View {
        if entry.isEmpty {
            Image(systemName: "calendar")
                .font(.system(size: diameter * 0.26, weight: .medium))
                .foregroundStyle(.secondary)
        } else if entry.isComplete {
            // The fraction is still "5 of 5", but a finished day has earned
            // something better to look at than arithmetic.
            Image(systemName: "checkmark")
                .font(.system(size: diameter * 0.34, weight: .bold))
                .foregroundStyle(.tint)
        } else {
            VStack(spacing: -1) {
                Text("\(entry.done)")
                    .font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded))
                Text("of \(entry.total)")
                    .font(.system(size: diameter * 0.16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // The ring's inside is a circle, so a long "of 12" needs room to
            // shrink rather than be clipped by the stroke.
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        }
    }
}

#if DEBUG
#Preview("Progress small", as: .systemSmall) {
    ProgressWidget()
} timeline: {
    GlanceEntry.placeholder
    GlanceEntry(date: .now, done: 5, total: 5, next: nil, isUnavailable: false)
    GlanceEntry(date: .now, done: 0, total: 0, next: nil, isUnavailable: false)
}

#Preview("Progress medium", as: .systemMedium) {
    ProgressWidget()
} timeline: {
    GlanceEntry.placeholder
    GlanceEntry(
        date: .now,
        done: 2,
        total: 6,
        next: .init(id: UUID(), title: "Water the plants", time: nil, colorHex: nil),
        isUnavailable: false
    )
    GlanceEntry(date: .now, done: 4, total: 4, next: nil, isUnavailable: false)
}
#endif
