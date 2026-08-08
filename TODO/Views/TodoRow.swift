import SwiftUI

/// One line in a todo list, in the spirit of Things: checkbox, title, and a
/// quiet row of metadata badges that only appear when they carry information.
struct TodoRow: View {
    @Bindable var todo: Todo
    var showsSpace: Bool = false
    var isSelected: Bool = false
    /// True while this row's title is being edited in place.
    var isEditingTitle: Bool = false
    let onToggle: () -> Void
    let onSelectState: (CompletionState) -> Void
    /// Called as the inline title changes, so the parser can re-run.
    var onTitleChange: (String) -> Void = { _ in }
    /// Called when the user commits the inline edit (return key or focus loss).
    var onCommitTitle: () -> Void = {}

    /// Drives focus for the inline field. Owned by the list so only one row
    /// edits at a time.
    @FocusState.Binding var titleFieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.rowSpacing) {
            TodoCheckbox(
                state: todo.state,
                tint: tint,
                onToggle: onToggle,
                onSelect: onSelectState
            )
            // Nudge the box onto the text's optical baseline.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            VStack(alignment: .leading, spacing: 3) {
                titleLine

                if !metadata.isEmpty {
                    metadataLine
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metrics.rowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        }
        .contentShape(Rectangle())
        .opacity(todo.state.isResolved ? 0.5 : 1)
        .animation(Theme.Animation.toggle, value: todo.state)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            // Marks a to-do the user has not yet seen in this list.
            if todo.isNew {
                Circle()
                    .fill(Theme.Palette.unviewed)
                    .frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("New")
            }

            if todo.isProject {
                Image(systemName: "list.bullet")
                    .font(.caption2)
                    .foregroundStyle(tint)
            }

            if isEditingTitle {
                // Editing in place shows the raw markdown source, so the user
                // can see and change the marks they typed.
                TextField("New To-Do", text: $todo.title)
                    .textFieldStyle(.plain)
                    .focused($titleFieldFocused)
                    .onChange(of: todo.title) { _, newValue in
                        onTitleChange(newValue)
                    }
                    .onSubmit { onCommitTitle() }
                    .submitLabel(.done)
            } else {
                InlineMarkdownText(
                    markdown: todo.title.isEmpty ? "New To-Do" : todo.title,
                    strikethrough: todo.state == .completed
                )
                .foregroundStyle(todo.title.isEmpty ? .secondary : .primary)
            }

            // Marks a todo pulled in from the system Reminders app.
            if todo.importedFromReminders {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Imported from Reminders")
            }
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 8) {
            ForEach(metadata) { badge in
                Label(badge.text, systemImage: badge.symbol)
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(badge.color)
            }
        }
    }

    /// Checkbox and accent color, from the todo's project or space.
    private var tint: Color {
        todo.resolvedColorHex.map { Color(hex: $0) } ?? Theme.Palette.accent
    }

    // MARK: Badges

    private struct Badge: Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
        let color: Color
    }

    /// Only the fields that are actually set produce a badge, keeping rows
    /// uncluttered.
    private var metadata: [Badge] {
        var badges: [Badge] = []

        if let assigned = todo.assignedDate {
            badges.append(Badge(
                text: ParsedSuggestion.describe(assigned, hasTime: todo.assignedHasTime),
                symbol: "calendar",
                color: .secondary
            ))
        }

        if let due = todo.dueDate {
            badges.append(Badge(
                text: ParsedSuggestion.describe(due, hasTime: todo.dueHasTime),
                symbol: "target",
                color: todo.isOverdue ? Theme.Palette.overdue : .secondary
            ))
        }

        if let duration = todo.duration {
            badges.append(Badge(
                text: ParsedSuggestion.describe(duration: duration),
                symbol: "clock",
                color: .secondary
            ))
        }

        if !todo.reminderList.isEmpty {
            badges.append(Badge(
                text: "\(todo.reminderList.count)",
                symbol: "bell",
                color: .secondary
            ))
        }

        let subtasks = todo.subtaskList
        if !subtasks.isEmpty {
            let done = subtasks.filter { $0.state.isResolved }.count
            badges.append(Badge(
                text: "\(done)/\(subtasks.count)",
                symbol: "checklist",
                color: .secondary
            ))
        }

        if !todo.notes.isEmpty {
            badges.append(Badge(text: "", symbol: "text.alignleft", color: .secondary))
        }

        if showsSpace, let space = todo.space {
            badges.append(Badge(text: space.name, symbol: space.symbolName, color: Color(hex: space.colorHex)))
        }

        return badges
    }
}
