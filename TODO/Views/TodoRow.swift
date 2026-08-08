import SwiftUI
import SwiftData

/// One line in a todo list, in the spirit of Things: checkbox, title, and a
/// quiet row of metadata badges that only appear when they carry information.
struct TodoRow: View {
    @Bindable var todo: Todo
    var showsSpace: Bool = false
    var isSelected: Bool = false
    let onToggle: () -> Void
    let onSelectState: (CompletionState) -> Void
    /// Called as the title changes, so the parser can re-run and the store save.
    var onTitleChange: (String) -> Void = { _ in }

    /// Which row's title currently holds focus, keyed by todo id.
    ///
    /// There is no edit "mode": every row is always a live field, and focus
    /// alone decides where typing goes. That keeps rows from being stuck in a
    /// state that outlives the screen they were edited on.
    @FocusState.Binding var focusedTodoID: UUID?

    /// The row's long-press menu.
    ///
    /// Attached here rather than by the caller so it can cover the text and
    /// metadata but *not* the checkbox — the checkbox has its own long press
    /// for the status picker, and the two would otherwise compete.
    var menu: () -> AnyView = { AnyView(EmptyView()) }

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
            // The menu covers the row's content but stops short of the
            // checkbox, so a long press there reaches the status picker.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { menu() }
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Marks a to-do the user has not yet seen in this list.
            if todo.isNew {
                Circle()
                    .fill(Theme.Palette.unviewed)
                    .frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("New")
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            }

            if todo.isProject {
                Image(systemName: "list.bullet")
                    .font(.caption2)
                    .foregroundStyle(tint)
            }

            // Always a live field: typing saves as it goes, and `axis:
            // .vertical` lets a long title wrap instead of running off the edge.
            TextField("New To-Do", text: $todo.title, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focusedTodoID, equals: todo.uuid)
                .strikethrough(todo.state == .completed)
                .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
                .onChange(of: todo.title) { _, newValue in
                    onTitleChange(newValue)
                }
                // Return commits rather than inserting a newline; titles are
                // single-paragraph and notes are where longer text belongs.
                .onSubmit { focusedTodoID = nil }

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

#if DEBUG
/// Hosts the `@FocusState` a row needs, which a preview cannot provide directly.
private struct TodoRowPreviewHost: View {
    let todos: [Todo]
    var showsSpace: Bool = false

    @FocusState private var focusedTodoID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(todos) { todo in
                TodoRow(
                    todo: todo,
                    showsSpace: showsSpace,
                    onToggle: {},
                    onSelectState: { _ in },
                    focusedTodoID: $focusedTodoID
                )
            }
        }
        .padding(.vertical)
    }
}

#Preview("States") {
    // One row per completion state, including the half-filled "started" box.
    let todos = CompletionState.allCases.map { state -> Todo in
        let todo = Todo(title: "\(state.label) to-do")
        PreviewData.context.insert(todo)
        todo.setState(state)
        return todo
    }
    return TodoRowPreviewHost(todos: todos)
        .previewEnvironment()
}

#Preview("Metadata") {
    // Dates, duration, reminders, subtask counts, space badges, and the
    // import and new markers.
    TodoRowPreviewHost(
        todos: [
            PreviewData.todo(titled: "Review"),
            PreviewData.todo(titled: "Standup"),
            PreviewData.todo(titled: "Pay the"),
            PreviewData.todo(titled: "Renew passport"),
            PreviewData.project,
            PreviewData.imported,
        ],
        showsSpace: true
    )
    .previewEnvironment()
}

#Preview("Long title") {
    // Titles wrap rather than running off the edge.
    TodoRowPreviewHost(todos: [PreviewData.longTitled])
        .previewEnvironment()
}
#endif
