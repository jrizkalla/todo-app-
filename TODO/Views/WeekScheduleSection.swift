import SwiftUI

/// The "plan this for a week" control in the to-do editor.
///
/// Sits directly beneath `DateTimeSection`'s Date & Time, because the two are
/// one decision seen at two resolutions: a day, or the week the day has not
/// been chosen from yet. Putting them next to each other is what makes the
/// exclusion between them legible — picking a week visibly empties the date
/// row above, which is exactly what it does to the stored row.
struct WeekScheduleSection: View {
    let todo: Todo
    var accent: Color = .accentColor
    /// Applies the choice. Nil means "no week", which the caller clears.
    let onChange: (WeekSchedule?) -> Void

    @Environment(AppSettings.self) private var settings

    private var calendar: Calendar { settings.calendar }

    /// The week the to-do currently reads as, through the user's week-start
    /// preference — see `SchedulePickerView.currentWeek` for why that matters.
    private var current: WeekSchedule? {
        todo.weekSchedule(calendar: calendar)
    }

    var body: some View {
        Section {
            ForEach(WeekSchedule.allCases, id: \.self) { week in
                Button {
                    // Tapping the selected row clears it, so the section can
                    // undo itself without a separate "None" row taking up a
                    // third of it.
                    onChange(current == week ? nil : week)
                } label: {
                    HStack {
                        Label(week.label, systemImage: week.symbolName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if current == week {
                            Image(systemName: "checkmark")
                                .foregroundStyle(accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Week")
        } footer: {
            Text(
                "Plan this for a week without picking a day. Choosing a week clears the date above, and picking a date clears the week."
            )
        }
    }
}
