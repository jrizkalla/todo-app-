import SwiftUI
import WidgetKit

// The Lock Screen accessory families exist only where there is a Lock Screen.
// macOS builds the same widget bundle and has no `accessoryInline`, so the
// whole widget — not merely the family list — is absent there rather than
// present and unplaceable.
#if !os(macOS)

/// The one-line slot above the lock screen clock: what's next.
///
/// `accessoryInline` is the narrowest surface the system offers — a single
/// line, no wrapping, tinted by the system rather than the app, and sharing its
/// width with a leading glyph.
///
/// It carries only the task. The slot sits in the row the Lock Screen already
/// uses for the date, and the system keeps drawing the date there alongside
/// whatever the widget returns — so a line that opened with the date of its own
/// showed it twice. What the widget adds to that row is the *task*; the date is
/// the system's to draw, and drawing it again is not this widget's job.
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
        .configurationDisplayName("Up Next")
        .description("The next thing on your list, above the clock.")
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

    /// The next task, or a short word standing in for it.
    ///
    /// A finished day says so — it is the one piece of news worth the width
    /// when there is no task to name. A day with nothing on it says "Nothing
    /// scheduled" rather than going blank: the slot is already shown at this
    /// point, so an empty string leaves the glyph stranded beside nothing,
    /// which reads as a broken widget rather than a free afternoon.
    var line: String {
        if entry.isUnavailable { return "Open TODO" }
        if let next = entry.next { return next.title }
        if entry.isComplete { return "All done" }
        return "Nothing scheduled"
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

#endif
