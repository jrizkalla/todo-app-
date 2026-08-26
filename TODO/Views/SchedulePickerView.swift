import SwiftUI

/// Quick scheduling panel, in the shape Things uses.
///
/// Shortcuts on top for the two answers people give most ("today", "tonight"),
/// a month grid for anything else, and Someday for work with no date at all.
/// Presented from a row's leading swipe.
struct SchedulePickerView: View {
    let todo: Todo
    /// Applies a new assigned date. `nil` clears it.
    let onPick: (Date?, _ hasTime: Bool) -> Void
    let onAddReminder: () -> Void
    let onDismiss: () -> Void
    /// Opens the recurrence panel. Nil where there is nowhere to open it.
    var onRepeat: (() -> Void)?

    /// Whether to show the typed-date field and focus it on open.
    ///
    /// True when the panel was raised from the keyboard (Cmd+S), where typing
    /// is the reason it opened. A swipe opens it with the field hidden, since a
    /// finger on a phone is not reaching for a keyboard next.
    var acceptsTypedDate = false

    @Environment(AppSettings.self) private var settings

    /// First day of the month the grid is showing.
    @State private var visibleMonth: Date = Date()

    private var calendar: Calendar { settings.calendar }
    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Hour "this evening" resolves to.
    private let eveningHour = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchedulePickerParts.Header(title: "When?", onDismiss: onDismiss)

            if acceptsTypedDate {
                QuickDateField(onCommit: { date, hasTime in
                    onPick(date, hasTime)
                })
                .padding(.bottom, 10)
            }

            shortcut(
                title: "Today",
                symbol: "star.fill",
                tint: .yellow,
                isSelected: isSelected(today) && !todo.assignedHasTime
            ) {
                onPick(today, false)
            }

            shortcut(
                title: "This Evening",
                symbol: "moon.fill",
                tint: .indigo,
                isSelected: isSelected(today) && todo.assignedHasTime
            ) {
                onPick(calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: today), true)
            }

            monthGrid

            shortcut(
                title: "Someday",
                symbol: "archivebox.fill",
                tint: .brown,
                isSelected: todo.assignedDate == nil && todo.isScheduled
            ) {
                // Someday is "no date", which the filing rules read as Anytime
                // when the to-do has a home and Inbox when it does not.
                onPick(nil, false)
            }

            Divider().padding(.vertical, 6)

            Button(action: onAddReminder) {
                Label("Add Reminder", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // "When?" and "how often?" are the same decision seen twice, so the
            // way to the repeat panel is here rather than only in the editor —
            // the swipe that schedules something is also where a user realises
            // it should recur.
            if let onRepeat {
                Button(action: onRepeat) {
                    Label(
                        todo.effectiveRecurrenceRule.map { "Repeats \($0.summary)" } ?? "Repeat…",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .font(.callout)
                    .foregroundStyle(todo.isRecurring ? Color.accentColor : .secondary)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            clearButton
        }
        .padding(16)
        .frame(maxWidth: 360)
        .onAppear {
            visibleMonth = todo.assignedDate ?? today
        }
    }

    /// Thin wrapper over the shared row, keeping this file's call sites
    /// unchanged while the drawing lives in `SchedulePickerParts`.
    private func shortcut(
        title: String,
        symbol: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SchedulePickerParts.Shortcut(
            title: title,
            symbol: symbol,
            tint: tint,
            isSelected: isSelected,
            action: action
        )
    }

    // MARK: Month grid

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Array(monthWeeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottomTrailing) {
            // Steps to the next month, like the chevron in the screenshot.
            Button {
                if let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth) {
                    withAnimation(Theme.Animation.toggle) { visibleMonth = next }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isPast = day < today
            let isToday = calendar.isDate(day, inSameDayAs: today)

            Button {
                onPick(day, false)
            } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    // Today is the anchor the whole grid is read against —
                    // "the 14th" means nothing until you can see where today
                    // falls — so it is weighted even when something else is
                    // the selected date.
                    .fontWeight(isToday ? .bold : .regular)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .foregroundStyle(dayForeground(isToday: isToday, isPast: isPast))
                    .background {
                        if isSelected(day) {
                            Circle().fill(Color.accentColor.opacity(0.22))
                        } else if isToday {
                            // A ring rather than a fill, so today never looks
                            // like the picked date. The two coincide often
                            // enough that they have to stay distinguishable —
                            // and when they do, the fill above wins and the
                            // bold weight still marks it as today.
                            Circle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: day, isToday: isToday))
        } else {
            // Padding for the days before the first of the month.
            Color.clear.frame(maxWidth: .infinity, minHeight: 32)
        }
    }

    /// Today keeps full-strength colour even though it is not in the future;
    /// dimming it would bury the one date the grid is read against.
    private func dayForeground(isToday: Bool, isPast: Bool) -> Color {
        if isToday { return .accentColor }
        return isPast ? .secondary : .primary
    }

    /// Spells out "Today" for VoiceOver, which cannot see the ring.
    private func accessibilityLabel(for day: Date, isToday: Bool) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return isToday ? "Today, \(date)" : date
    }

    private var clearButton: some View {
        SchedulePickerParts.DestructiveButton(title: "Clear") {
            onPick(nil, false)
        }
    }

    // MARK: Dates

    private func isSelected(_ day: Date) -> Bool {
        guard let assigned = todo.assignedDate else { return false }
        return calendar.isDate(assigned, inSameDayAs: day)
    }

    /// Weekday initials in the user's week-start order.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    /// The visible month laid out as weeks, padded with nils so the first day
    /// lands under the right weekday.
    private var monthWeeks: [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayCount = calendar.range(of: .day, in: .month, for: visibleMonth)?.count
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }

        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
    }
}
