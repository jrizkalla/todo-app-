import SwiftUI

/// Quick scheduling panel, in the shape Things uses.
///
/// Shortcuts on top for the two answers people give most ("today", "tonight"),
/// a month grid for anything else, and Someday for work with no date at all.
/// Presented from a row's leading swipe.
struct SchedulePickerView: View {
    /// The to-do being scheduled, when there is exactly one.
    ///
    /// `nil` when the panel was opened over a multi-row selection. Everything
    /// it feeds is a *current value* readout — which shortcut is ticked, which
    /// month the grid opens on, what the repeat row says — and a batch has no
    /// single current value to report. The answers the panel produces are the
    /// same either way, which is why one panel serves both.
    var todo: Todo?
    /// Applies a new assigned date. `nil` clears it.
    let onPick: (Date?, _ hasTime: Bool) -> Void
    /// Plans the to-do into a week instead of onto a day.
    ///
    /// Separate from `onPick` rather than folded into it as a nil date, because
    /// the two say opposite things: `onPick(nil, _)` means "no date at all",
    /// which is Someday, while this means "a date I have not picked yet, inside
    /// this week". Collapsing them would make the panel unable to express the
    /// difference the whole feature is about.
    let onPickWeek: (WeekSchedule) -> Void
    /// Opens the full reminder editor. Nil over a selection, where a reminder
    /// is a per-to-do thing and the editor takes one row.
    var onAddReminder: (() -> Void)?
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
                QuickDateField(
                    onCommit: { date, hasTime in
                        onPick(date, hasTime)
                    },
                    // So typing "next week" does the same thing as tapping the
                    // Next Week row below it. The field is the keyboard route
                    // into this panel, and a phrase the panel offers as a
                    // button has to be one the field can take.
                    onCommitWeek: { week in
                        onPickWeek(week)
                    }
                )
                .padding(.bottom, 10)
            }

            shortcut(
                title: "Today",
                symbol: "star.fill",
                tint: .yellow,
                isSelected: isSelected(today) && todo?.assignedHasTime == false
            ) {
                onPick(today, false)
            }

            shortcut(
                title: "This Evening",
                symbol: "moon.fill",
                tint: .indigo,
                isSelected: isSelected(today) && todo?.assignedHasTime == true
            ) {
                onPick(calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: today), true)
            }

            // Above the grid, with the other shortcuts, because they answer the
            // same question the grid does — just less precisely. Most work that
            // is not for today is "sometime this week", and making the user
            // pick an arbitrary Wednesday to express that is what these are
            // here to avoid.
            ForEach(WeekSchedule.allCases, id: \.self) { week in
                shortcut(
                    title: week.label,
                    symbol: week.symbolName,
                    tint: week == .thisWeek ? .green : .mint,
                    isSelected: currentWeek == week
                ) {
                    onPickWeek(week)
                }
            }

            monthGrid

            shortcut(
                title: "Someday",
                symbol: "archivebox.fill",
                tint: .brown,
                // A week-planned to-do is not Someday: it has been placed in
                // time, just not on a day. Without the week test here both rows
                // would read as selected at once.
                isSelected: todo.map {
                    $0.assignedDate == nil && $0.weekAnchor == nil && $0.isScheduled
                } ?? false
            ) {
                // Someday is "no date", which the filing rules read as Anytime
                // when the to-do has a home and Inbox when it does not.
                onPick(nil, false)
            }

            Divider().padding(.vertical, 6)

            if let onAddReminder {
                Button(action: onAddReminder) {
                    Label("Add Reminder", systemImage: "plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            // "When?" and "how often?" are the same decision seen twice, so the
            // way to the repeat panel is here rather than only in the editor —
            // the swipe that schedules something is also where a user realises
            // it should recur.
            if let onRepeat {
                Button(action: onRepeat) {
                    Label(
                        todo?.effectiveRecurrenceRule.map { "Repeats \($0.summary)" } ?? "Repeat…",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .font(.callout)
                    .foregroundStyle(todo?.isRecurring == true ? Color.accentColor : .secondary)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            clearButton
        }
        .padding(16)
        .frame(maxWidth: 360)
        .onAppear {
            visibleMonth = todo?.assignedDate ?? today
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

            monthNavigation
        }
        .padding(.vertical, 8)
    }

    /// Steps the grid a month at a time, with the month it is showing between
    /// the two chevrons.
    ///
    /// The label is what makes the chevrons safe to press: once the grid can
    /// move in both directions the dates alone no longer say which month is on
    /// screen, and a bare "14" in an unnamed month is a scheduling mistake
    /// waiting to happen. The year rides along only when it is not the current
    /// one, so the common case stays short.
    private var monthNavigation: some View {
        HStack {
            monthStepButton(by: -1, symbol: "chevron.left", label: "Previous month")

            Spacer(minLength: 8)

            Text(visibleMonth.formatted(monthLabelFormat))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                // So stepping between a short month and a long one does not
                // shuffle the chevrons under the user's finger.
                .frame(minWidth: 96)
                .contentTransition(.identity)

            Spacer(minLength: 8)

            monthStepButton(by: 1, symbol: "chevron.right", label: "Next month")
        }
        .padding(.top, 2)
    }

    private func monthStepButton(by months: Int, symbol: String, label: String) -> some View {
        Button {
            if let stepped = calendar.date(byAdding: .month, value: months, to: visibleMonth) {
                withAnimation(Theme.Animation.toggle) { visibleMonth = stepped }
            }
        } label: {
            Image(systemName: symbol)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                // A caption glyph is a few points across; without a padded hit
                // area this is a miss on a phone more often than not.
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "September", or "September 2027" once the grid has left this year.
    private var monthLabelFormat: Date.FormatStyle {
        let sameYear = calendar.isDate(visibleMonth, equalTo: today, toGranularity: .year)
        return sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year()
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
        guard let assigned = todo?.assignedDate else { return false }
        return calendar.isDate(assigned, inSameDayAs: day)
    }

    /// The week shortcut currently reflecting this to-do, if either does.
    ///
    /// Read through the calendar the panel is using rather than the default
    /// one, so the highlight agrees with the user's week-start preference — a
    /// Sunday to-do is "this week" or "last week" depending on that setting,
    /// and the picker must not disagree with the list it schedules into.
    private var currentWeek: WeekSchedule? {
        todo?.weekSchedule(calendar: calendar)
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
