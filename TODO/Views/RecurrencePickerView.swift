import SwiftUI

/// The "how often?" panel, deliberately built to read as the sibling of
/// `SchedulePickerView`'s "When?".
///
/// The two are presented the same way, from the same kinds of gesture, and a
/// user moving between them should feel one panel with a different question at
/// the top — so the header, the shortcut rows, the month grid, and the
/// destructive footer button are the *same* components, pulled out of the
/// schedule picker into `SchedulePickerParts` rather than reimplemented here.
///
/// What is genuinely new is the middle: the three recurrence modes the spec
/// names, an interval, and the mode-dependent controls beneath them.
struct RecurrencePickerView: View {
    /// The to-do the schedule is being set on. May be the template itself or
    /// one of its instances — `TodoStore.setRecurrence` resolves that.
    let todo: Todo
    /// Applies a rule. `nil` stops the to-do recurring.
    let onPick: (RecurrenceRule?) -> Void
    /// Pause / resume / cancel, kept separate from `onPick` because they are
    /// lifecycle actions rather than edits to the schedule.
    var onSetStatus: ((RecurrenceStatus) -> Void)?
    let onDismiss: () -> Void

    @Environment(AppSettings.self) private var settings

    /// The rule being assembled. Seeded from whatever the to-do already has, so
    /// reopening the panel shows the current schedule rather than a default.
    @State private var draft = RecurrenceRule()
    /// Whether the end-date row is expanded into its grid.
    @State private var isChoosingEndDate = false
    /// Whether the time-of-day row is expanded into its picker.
    @State private var isChoosingTime = false

    private var calendar: Calendar { settings.calendar }

    /// True when this to-do already repeats, which decides whether the footer
    /// offers "Stop Repeating" and the pause/cancel controls at all.
    private var isAlreadyRecurring: Bool { todo.effectiveRecurrenceRule != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SchedulePickerParts.Header(title: "Repeat", onDismiss: onDismiss)

                modeSection

                Divider().padding(.vertical, 10)

                frequencySection

                if draft.mode.usesCalendarAnchor {
                    switch draft.frequency {
                    case .weekly: weekdaySection
                    case .monthly: dayOfMonthSection
                    case .daily, .yearly: EmptyView()
                    }

                    Divider().padding(.vertical, 10)
                    timeSection
                }

                Divider().padding(.vertical, 10)

                endDateSection

                if isAlreadyRecurring {
                    Divider().padding(.vertical, 10)
                    statusSection
                }

                saveButton

                if isAlreadyRecurring {
                    SchedulePickerParts.DestructiveButton(title: "Stop Repeating") {
                        onPick(nil)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: 380)
        .onAppear {
            // An instance reads its template's rule, so editing the schedule
            // from any occurrence shows — and changes — the same series.
            draft = todo.effectiveRecurrenceRule ?? defaultRule()
        }
    }

    /// A sensible starting schedule for a to-do that does not yet repeat.
    ///
    /// Seeded from the to-do's own date when it has one: the user picked a day,
    /// then asked for it to repeat, so "every week on that weekday" is what
    /// they almost certainly mean.
    private func defaultRule() -> RecurrenceRule {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .weekly, interval: 1)
        if let assigned = todo.assignedDate {
            rule.weekdays = [calendar.component(.weekday, from: assigned)]
            if todo.assignedHasTime {
                let parts = calendar.dateComponents([.hour, .minute], from: assigned)
                rule.timeOfDayMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        }
        return rule
    }

    // MARK: Mode

    /// The three answers the spec asks for, as shortcut rows.
    ///
    /// Each carries its explanation underneath rather than only a title: the
    /// difference between "on schedule" and "on schedule, after completion" is
    /// real but not self-evident from a label, and burying it in a help tooltip
    /// would leave the choice a guess on a phone.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchedulePickerParts.SectionLabel("Repeats")

            ForEach(RecurrenceMode.allCases, id: \.self) { mode in
                SchedulePickerParts.Shortcut(
                    title: mode.label,
                    subtitle: mode.explanation,
                    symbol: mode.symbolName,
                    tint: tint(for: mode),
                    isSelected: draft.mode == mode
                ) {
                    withAnimation(Theme.Animation.toggle) { draft.mode = mode }
                }
            }
        }
    }

    private func tint(for mode: RecurrenceMode) -> Color {
        switch mode {
        case .onSchedule: .blue
        case .afterCompletionOnSchedule: .indigo
        case .afterCompletion: .green
        }
    }

    // MARK: Frequency and interval

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SchedulePickerParts.SectionLabel(
                draft.mode == .afterCompletion ? "Wait" : "Every"
            )

            HStack(spacing: 10) {
                Stepper(value: $draft.interval, in: 1...99) {
                    Text(intervalText)
                        .font(.callout)
                        .monospacedDigit()
                }

                Picker("", selection: $draft.frequency) {
                    ForEach(RecurrenceFrequency.allCases, id: \.self) { frequency in
                        Text(draft.interval == 1 ? frequency.unitName : frequency.pluralUnitName)
                            .tag(frequency)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var intervalText: String {
        draft.interval == 1 ? "Every" : "Every \(draft.interval)"
    }

    // MARK: Weekly

    /// The weekday strip, in the user's week-start order.
    ///
    /// Multi-select, because "every Monday and Thursday" is an ordinary
    /// schedule and a single-choice control could not express it.
    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SchedulePickerParts.SectionLabel("On")

            HStack(spacing: 4) {
                ForEach(orderedWeekdays, id: \.self) { weekday in
                    let isOn = draft.weekdays.contains(weekday)
                    Button {
                        withAnimation(Theme.Animation.toggle) { toggle(weekday) }
                    } label: {
                        Text(weekdayInitial(weekday))
                            .font(.caption)
                            .fontWeight(isOn ? .semibold : .regular)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .foregroundStyle(isOn ? Color.white : .primary)
                            .background {
                                Circle().fill(
                                    isOn ? Color.accentColor : Color.secondary.opacity(0.14)
                                )
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(weekdayName(weekday))
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }

            // Empty is legal and means "whatever weekday the date falls on",
            // so the panel says so rather than leaving a silent no-op.
            if draft.weekdays.isEmpty {
                Text("No days chosen — repeats on the same weekday as the current date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func toggle(_ weekday: Int) {
        if draft.weekdays.contains(weekday) {
            draft.weekdays.remove(weekday)
        } else {
            draft.weekdays.insert(weekday)
        }
    }

    private var orderedWeekdays: [Int] {
        let start = calendar.firstWeekday
        return (0..<7).map { ((start - 1 + $0) % 7) + 1 }
    }

    private func weekdayInitial(_ weekday: Int) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        guard (1...7).contains(weekday) else { return "" }
        return symbols[weekday - 1]
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = calendar.weekdaySymbols
        guard (1...7).contains(weekday) else { return "" }
        return symbols[weekday - 1]
    }

    // MARK: Monthly

    private var dayOfMonthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SchedulePickerParts.SectionLabel("On day")

            Picker("", selection: Binding(
                get: { draft.dayOfMonth ?? 0 },
                set: { draft.dayOfMonth = $0 == 0 ? nil : $0 }
            )) {
                Text("Same as the date").tag(0)
                ForEach(1...31, id: \.self) { day in
                    Text(RecurrenceRule.ordinal(day)).tag(day)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            // Months are not all the same length, and silently skipping
            // February is the kind of thing a user only notices in March.
            if let day = draft.dayOfMonth, day > 28 {
                Text("Months without a \(RecurrenceRule.ordinal(day)) use their last day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Time of day

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { draft.timeOfDayMinutes != nil },
                set: { enabled in
                    withAnimation(Theme.Animation.toggle) {
                        // Nine in the morning rather than midnight: an
                        // instance created at 00:00 reads as untimed even
                        // though it is not.
                        draft.timeOfDayMinutes = enabled ? 9 * 60 : nil
                        isChoosingTime = enabled
                    }
                }
            )) {
                HStack(spacing: 10) {
                    SchedulePickerParts.icon("clock", tint: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("At a time")
                        if let phrase = draft.timePhrase {
                            Text(phrase)
                                .font(.footnote)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if draft.timeOfDayMinutes != nil && isChoosingTime {
                DatePicker(
                    "",
                    selection: timeBinding,
                    displayedComponents: [.hourAndMinute]
                )
                #if os(iOS)
                .datePickerStyle(.wheel)
                #endif
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Bridges the stored minutes-since-midnight to the `Date` a picker wants.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = (draft.timeOfDayMinutes ?? 540) / 60
                components.minute = (draft.timeOfDayMinutes ?? 540) % 60
                return calendar.date(from: components) ?? Date()
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                draft.timeOfDayMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    // MARK: End date

    private var endDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { draft.endDate != nil },
                set: { enabled in
                    withAnimation(Theme.Animation.toggle) {
                        draft.endDate = enabled
                            ? calendar.date(byAdding: .month, value: 3, to: Date())
                            : nil
                        isChoosingEndDate = enabled
                    }
                }
            )) {
                HStack(spacing: 10) {
                    SchedulePickerParts.icon("calendar.badge.exclamationmark", tint: .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("End date")
                        if let endDate = draft.endDate {
                            Text(endDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if draft.endDate != nil && isChoosingEndDate {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { draft.endDate ?? Date() },
                        set: { draft.endDate = $0 }
                    ),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Status

    /// Pause / resume / cancel, the lifecycle controls the spec asks for.
    ///
    /// Applied immediately rather than on Save: they are decisions about the
    /// series as it stands, not edits to the draft, and a user reaching for
    /// Pause does not expect to have to confirm a schedule they did not change.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchedulePickerParts.SectionLabel("Series")

            let current = todo.effectiveRecurrenceRule?.status ?? .active

            if current == .active {
                SchedulePickerParts.Shortcut(
                    title: "Pause",
                    subtitle: "Stop creating new ones, and keep the schedule.",
                    symbol: "pause.circle.fill",
                    tint: .orange,
                    isSelected: false
                ) {
                    onSetStatus?(.paused)
                }
            } else {
                SchedulePickerParts.Shortcut(
                    title: "Resume",
                    subtitle: "Start creating new ones again, from today.",
                    symbol: "play.circle.fill",
                    tint: .green,
                    isSelected: false
                ) {
                    onSetStatus?(.active)
                }
            }

            if current != .cancelled {
                SchedulePickerParts.Shortcut(
                    title: "Cancel Series",
                    subtitle: "End the repetition. Existing to-dos are kept.",
                    symbol: "xmark.circle.fill",
                    tint: .red,
                    isSelected: false
                ) {
                    onSetStatus?(.cancelled)
                }
            }
        }
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            onPick(draft.normalized())
        } label: {
            Text(isAlreadyRecurring ? "Update Schedule" : "Repeat \(draft.normalized().summary)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background { Capsule().fill(Color.accentColor) }
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}

#if DEBUG
#Preview("New schedule") {
    RecurrencePickerView(
        todo: PreviewData.todo(titled: "Water the plants"),
        onPick: { _ in },
        onSetStatus: { _ in },
        onDismiss: {}
    )
    .previewEnvironment()
}
#endif
