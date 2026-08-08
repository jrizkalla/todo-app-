import SwiftUI

/// A reminder from the Reminders app that has not been imported yet.
///
/// Deliberately not a `TodoRow`: it has no checkbox, since it is not yet a
/// to-do in this app. The import button is the only action, and it reads as a
/// preview of what would arrive.
struct PendingReminderRow: View {
    let reminder: PendingReminder
    let onImport: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.rowSpacing) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Metrics.checkboxSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Label(reminder.listTitle, systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let due = reminder.dueDate {
                        Label(
                            ParsedSuggestion.describe(due, hasTime: reminder.dueHasTime),
                            systemImage: "target"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(action: onImport) {
                Text("Import")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background { Capsule().fill(Color.accentColor.opacity(0.15)) }
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import \(reminder.title)")
        }
        .padding(.vertical, Theme.Metrics.rowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding)
        .contentShape(Rectangle())
    }
}

/// Header above the pending rows, with the bulk action.
struct PendingRemindersHeader: View {
    let count: Int
    let onImportAll: () -> Void

    var body: some View {
        HStack {
            Text("From Reminders")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Import All", action: onImportAll)
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .textCase(nil)
    }
}
