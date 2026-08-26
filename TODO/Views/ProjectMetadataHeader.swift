import SwiftUI

/// A project's own scheduling, shown above the work it holds.
///
/// A project is a to-do, so it can be scheduled and given a deadline like any
/// other — but opening it navigated straight to its *contents*, and those dates
/// appeared nowhere. The project with the deadline was the one thing its own
/// list would not tell you about.
///
/// Deliberately a summary rather than an editor. Editing happens on the
/// project's detail page, which already has the full set of controls; tapping
/// here opens it rather than reimplementing date pickers in a header.
struct ProjectMetadataHeader: View {
    let project: Todo
    /// Opens the project's detail page.
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 10) {
                if let assigned = project.assignedDate {
                    badge(
                        symbol: "calendar",
                        text: ParsedSuggestion.describe(assigned, hasTime: project.assignedHasTime),
                        tint: .secondary
                    )
                }

                if let due = project.dueDate {
                    badge(
                        symbol: "target",
                        text: ParsedSuggestion.describe(due, hasTime: project.dueHasTime),
                        // The same red the rows use, so a late project reads as
                        // late in the one place the whole list can see it.
                        tint: project.isOverdue ? Theme.Palette.overdue : .secondary
                    )
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the project's details")
    }

    private func badge(symbol: String, text: String, tint: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .labelStyle(.titleAndIcon)
    }

    /// One spoken phrase rather than two loose dates, so the badges are not
    /// read out as unlabelled fragments.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let assigned = project.assignedDate {
            parts.append(
                "Scheduled \(ParsedSuggestion.describe(assigned, hasTime: project.assignedHasTime))"
            )
        }
        if let due = project.dueDate {
            let phrase = ParsedSuggestion.describe(due, hasTime: project.dueHasTime)
            parts.append(project.isOverdue ? "Deadline \(phrase), overdue" : "Deadline \(phrase)")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Project metadata") {
    let project = PreviewData.project
    project.assignedDate = Date()
    project.dueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())

    return ProjectMetadataHeader(project: project) {}
        .padding()
        .previewEnvironment()
}
#endif
