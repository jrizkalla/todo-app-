import SwiftUI
import SwiftData

/// The "Repeat" block in the to-do editors.
///
/// Two presentations of one thing, because the two editors are built on
/// different chrome: `RecurrenceSection` is a `Form` section for the iOS editor,
/// and `RecurrenceCardContent` is the bare stack the macOS popover drops into
/// its own card. They share `RecurrenceSummaryRow` and the same store calls, so
/// the two cannot disagree about what the schedule says or what the buttons do.
struct RecurrenceSection: View {
    let todo: Todo
    /// Raises the recurrence panel. The section itself never presents — the
    /// editors differ on how a panel is shown (sheet, popover), and each owns
    /// that decision.
    let onEdit: () -> Void

    @Environment(\.modelContext) private var context

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        Section {
            RecurrenceSummaryRow(todo: todo, onEdit: onEdit)

            if todo.isRecurring {
                RecurrenceActions(todo: todo, store: store)
            }

            if todo.isRecurrenceInstance {
                RecurrenceSeriesFootnote(todo: todo)
            }
        } header: {
            Text("Repeat")
        } footer: {
            Text(footnote)
        }
    }

    private var footnote: String {
        guard let rule = todo.effectiveRecurrenceRule else {
            return "Make this to-do come back on a schedule."
        }
        switch rule.status {
        case .active:
            return todo.isRecurrenceInstance
                ? "This is one occurrence. Changing the schedule changes the whole series."
                : "The next one is created automatically."
        case .paused:
            return "Paused — no new ones are being created. The schedule is kept."
        case .cancelled:
            return "Cancelled — the series has ended. To-dos already created are kept."
        }
    }
}

/// The line that says what the schedule is, and opens the panel when tapped.
///
/// The same clickable-text idea as the row's chip: a sentence a user can read,
/// tinted to show it is live. Shared by both editors.
struct RecurrenceSummaryRow: View {
    let todo: Todo
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.isRecurring ? "Repeats" : "Does not repeat")
                        .foregroundStyle(.primary)
                    if let rule = todo.effectiveRecurrenceRule {
                        Text(rule.summary)
                            .font(.footnote)
                            .foregroundStyle(tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            todo.effectiveRecurrenceRule.map { "Repeats \($0.summary). Edit schedule" }
                ?? "Does not repeat. Set a schedule"
        )
    }

    private var symbol: String {
        guard let rule = todo.effectiveRecurrenceRule else {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        switch rule.status {
        case .active: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        guard let rule = todo.effectiveRecurrenceRule else { return .secondary }
        switch rule.status {
        case .active: return .accentColor
        case .paused: return .orange
        case .cancelled: return .red
        }
    }
}

/// Pause / resume / cancel, plus skip on an occurrence.
///
/// Inline buttons rather than a menu: these are the actions the section exists
/// to make reachable, and burying them one tap deeper in an editor that is
/// already a scroll would defeat the point.
struct RecurrenceActions: View {
    let todo: Todo
    let store: TodoStore

    var body: some View {
        let status = todo.effectiveRecurrenceRule?.status ?? .active

        if status == .active {
            Button {
                store.setRecurrenceStatus(.paused, on: todo)
            } label: {
                Label("Pause", systemImage: "pause.circle")
            }
        } else {
            Button {
                store.setRecurrenceStatus(.active, on: todo)
            } label: {
                Label("Resume", systemImage: "play.circle")
            }
        }

        // Skipping is an occurrence-level action: it says this one did not
        // happen and the series should move on.
        if todo.isRecurrenceInstance {
            Button {
                store.skipRecurrenceInstance(todo)
            } label: {
                Label("Skip This One", systemImage: "forward.end")
            }
        }

        if status != .cancelled {
            Button(role: .destructive) {
                store.setRecurrenceStatus(.cancelled, on: todo)
            } label: {
                Label("Cancel Series", systemImage: "xmark.circle")
            }
        }

        Button(role: .destructive) {
            store.setRecurrence(nil, on: todo)
        } label: {
            Label("Stop Repeating", systemImage: "trash")
        }
    }
}

/// On an occurrence: where it sits in the series, and when the next one lands.
///
/// The question a user opening a recurring to-do actually has — "is this the
/// one I skipped, and when does the next come round?" — which the schedule
/// sentence alone does not answer.
struct RecurrenceSeriesFootnote: View {
    let todo: Todo

    var body: some View {
        if let template = todo.recurrenceTemplate {
            VStack(alignment: .leading, spacing: 2) {
                if let next = template.recurrenceNextDate {
                    Text("Next: \(ParsedSuggestion.describe(next, hasTime: template.recurrenceRule?.hasTime ?? false))")
                }
                let done = template.recurrenceInstanceList.filter { $0.state == .completed }.count
                if done > 0 {
                    Text("\(done) completed so far")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Recurring") {
    let todo = PreviewData.todo(titled: "Water the plants")
    todo.recurrenceRule = RecurrenceRule(
        mode: .onSchedule, frequency: .weekly, interval: 1, weekdays: [2]
    )

    return Form {
        RecurrenceSection(todo: todo) {}
    }
    .formStyle(.grouped)
    .previewEnvironment()
}
#endif
