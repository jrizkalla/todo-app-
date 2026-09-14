import SwiftUI
import WidgetKit

/// The one-line slot above the lock screen clock: the date, then what's next.
///
/// `accessoryInline` is the narrowest surface the system offers — a single
/// line, no wrapping, tinted by the system rather than the app, and sharing its
/// width with a leading glyph. So the content is chosen by what survives
/// truncation: the date first, because it is short, fixed-width and always
/// true, then the next task, which is the part worth reading and the part that
/// can afford to be cut.
///
/// The task it names is `TodoQueries.widgetNextUp`, the same one the progress
/// widget's medium body shows — the two are visible at the same moment on the
/// same device, so they must not disagree.
struct InlineNextWidget: Widget {
    static let kind = "TodayInlineNextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlanceTimelineProvider()) { entry in
            InlineNextWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Date & Next")
        .description("The date and the next thing on your list.")
        .supportedFamilies([.accessoryInline])
    }
}

struct InlineNextWidgetView: View {
    let entry: GlanceEntry

    var body: some View {
        // A `Label` rather than bare text: the inline slot draws the image in
        // the space it reserves ahead of the line, so the glyph is effectively
        // free — where putting it in the string would spend characters the
        // task title needs.
        Label(line, systemImage: "star.fill")
    }

    /// "Mon 14 · Standup", degrading to just the date when there is nothing to
    /// name.
    ///
    /// The separator is a middle dot with hair spaces around it rather than a
    /// hyphen or a comma: the two halves are unrelated facts sitting side by
    /// side, not a range and not a list.
    private var line: String {
        let date = Self.dateText(for: entry.date)
        guard let title = subtitle else { return date }
        return "\(date) · \(title)"
    }

    /// What follows the date.
    ///
    /// A finished day says so — it is the one piece of news worth the width
    /// when there is no task to name. An empty day says nothing at all and
    /// leaves the line as a plain date, which is the honest thing for a lock
    /// screen to show on a day with no plans.
    private var subtitle: String? {
        if entry.isUnavailable { return nil }
        if let next = entry.next { return next.title }
        if entry.isComplete { return "All done" }
        return nil
    }

    /// "Mon 14" — weekday and day of month.
    ///
    /// Written as a format rather than a fixed string so it follows the
    /// device's locale and calendar: the abbreviation, and whether the number
    /// leads or trails, are not the app's to decide.
    static func dateText(for date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.abbreviated).day()
        )
    }
}

#if DEBUG
#Preview("Inline", as: .accessoryInline) {
    InlineNextWidget()
} timeline: {
    GlanceEntry.placeholder
    GlanceEntry(date: .now, done: 4, total: 4, next: nil, isUnavailable: false)
    GlanceEntry(date: .now, done: 0, total: 0, next: nil, isUnavailable: false)
}
#endif
