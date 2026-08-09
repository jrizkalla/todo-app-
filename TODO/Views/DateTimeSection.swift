import SwiftUI

/// A date-and-time editor styled after the stock Reminders app.
///
/// Reminders shows one row per component with a colored icon, a subtitle
/// carrying the current value, and a switch. Turning a switch on expands the
/// matching picker inline — a month grid for the date, a wheel for the time —
/// rather than pushing a separate screen, and turning the date off takes the
/// time with it, since a time with no day means nothing.
struct DateTimeSection: View {
    let title: String
    @Binding var date: Date?
    @Binding var hasTime: Bool
    /// Icon tint, matching the accent used elsewhere in the editor.
    var accent: Color = .accentColor
    /// Optional trailing content, used for the "Urgent" row the reminder editor
    /// shows beneath the time picker.
    var footnote: String?
    let onChange: () -> Void

    /// Which picker is currently expanded. Only one is open at a time, the way
    /// Reminders behaves — opening the time collapses the date grid.
    @State private var expanded: Component?

    private enum Component { case date, time }

    private var isDateOn: Bool { date != nil }

    var body: some View {
        Section {
            dateRow

            if isDateOn && expanded == .date {
                DatePicker(
                    "",
                    selection: boundDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(accent)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isDateOn {
                timeRow

                if hasTime && expanded == .time {
                    DatePicker(
                        "",
                        selection: boundDate,
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
        } header: {
            Text(title)
        } footer: {
            if let footnote {
                Text(footnote)
            }
        }
    }

    // MARK: Rows

    private var dateRow: some View {
        toggleRow(
            label: "Date",
            symbol: "calendar",
            symbolColor: .red,
            subtitle: isDateOn ? dateSubtitle : nil,
            isOn: Binding(
                get: { isDateOn },
                set: { enabled in
                    withAnimation(Theme.Animation.toggle) {
                        if enabled {
                            date = Calendar.current.startOfDay(for: Date())
                            expanded = .date
                        } else {
                            // A time without a day is meaningless, so the two
                            // switch off together.
                            date = nil
                            hasTime = false
                            expanded = nil
                        }
                    }
                    onChange()
                }
            ),
            onTapLabel: {
                guard isDateOn else { return }
                withAnimation(Theme.Animation.toggle) {
                    expanded = expanded == .date ? nil : .date
                }
            }
        )
    }

    private var timeRow: some View {
        toggleRow(
            label: "Time",
            symbol: "clock",
            symbolColor: .blue,
            subtitle: hasTime ? timeSubtitle : nil,
            isOn: Binding(
                get: { hasTime },
                set: { enabled in
                    withAnimation(Theme.Animation.toggle) {
                        hasTime = enabled
                        if enabled {
                            // Default to the next round hour rather than
                            // whatever midnight the date carries.
                            date = defaultTime(for: date ?? Date())
                            expanded = .time
                        } else {
                            expanded = nil
                        }
                    }
                    onChange()
                }
            ),
            onTapLabel: {
                guard hasTime else { return }
                withAnimation(Theme.Animation.toggle) {
                    expanded = expanded == .time ? nil : .time
                }
            }
        )
    }

    /// One Reminders-style row: tinted icon tile, label over its current value,
    /// and a switch.
    private func toggleRow(
        label: String,
        symbol: String,
        symbolColor: Color,
        subtitle: String?,
        isOn: Binding<Bool>,
        onTapLabel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(symbolColor)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(accent)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        // Only the label area toggles the picker; the switch keeps its own hit
        // area so tapping it never also expands the row.
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapLabel)
        .accessibilityElement(children: .combine)
    }

    // MARK: Values

    private var boundDate: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { date = $0; onChange() }
        )
    }

    /// "Today" for the current day, otherwise a short date — the wording
    /// Reminders uses.
    private var dateSubtitle: String {
        guard let date else { return "" }
        let calendar = Calendar.current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var timeSubtitle: String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Next round hour on the given day, so switching Time on lands somewhere
    /// sensible instead of 12:00 AM.
    private func defaultTime(for day: Date) -> Date {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())
        return calendar.date(bySettingHour: min(hour + 1, 23), minute: 0, second: 0, of: day) ?? day
    }
}

#if DEBUG
#Preview("Date & time") {
    @Previewable @State var date: Date? = Date()
    @Previewable @State var hasTime = true

    return Form {
        DateTimeSection(
            title: "Date & Time",
            date: $date,
            hasTime: $hasTime,
            accent: .blue,
            footnote: "Pick the day this to-do is planned for."
        ) {}
    }
    .formStyle(.grouped)
}
#endif
