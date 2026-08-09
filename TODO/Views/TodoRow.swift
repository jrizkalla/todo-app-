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
    /// Called as the inline notes change, so edits are saved as they are typed.
    var onNotesChange: () -> Void = {}

    /// Which row's title currently holds focus, keyed by todo id.
    ///
    /// There is no edit "mode": every row is always a live field, and focus
    /// alone decides where typing goes. That keeps rows from being stuck in a
    /// state that outlives the screen they were edited on.
    @FocusState.Binding var focusedTodoID: UUID?

    /// Which of this row's two fields holds focus, once the row is expanded.
    ///
    /// Separate from `focusedTodoID` because that identifies *which row* the
    /// keyboard belongs to, while the row itself has a title and a notes field
    /// to move between.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case notes }

    /// Local buffer for the title field. See the field's binding for why the
    /// model is not written directly.
    @State private var draftTitle: String = ""

    /// True when this row owns the keyboard, which is what expands it.
    private var isFocused: Bool {
        focusedTodoID == todo.uuid || focusedField != nil
    }

    private var backgroundFill: Color {
        if isFocused { return Color.secondary.opacity(0.10) }
        return isSelected ? Color.accentColor.opacity(0.12) : .clear
    }

    /// The row's long-press menu.
    ///
    /// Attached here rather than by the caller so it can cover the text and
    /// metadata but *not* the checkbox — the checkbox has its own long press
    /// for the status picker, and the two would otherwise compete.
    var menu: () -> AnyView = { AnyView(EmptyView()) }

    /// Called when Return is pressed in the title field.
    ///
    /// Creating the next to-do rather than dismissing the keyboard is what
    /// makes typing out a list in one pass possible.
    var onSubmitTitle: () -> Void = {}

    /// Called from the expanded row's button to open the full editor.
    var onShowDetail: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.rowSpacing) {
            TodoCheckbox(
                state: todo.state,
                tint: todo.color,
                onToggle: onToggle,
                onSelect: onSelectState
            )
            // Nudge the box onto the text's optical baseline.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            VStack(alignment: .leading, spacing: 3) {
                titleLine

                // Focused rows expand to expose notes inline, so a quick
                // thought can be captured without leaving the list. Collapsed
                // rows show only a summary badge.
                if isFocused {
                    TextField("Notes", text: $todo.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .lineLimit(1...4)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .notes)
                        .onChange(of: todo.notes) { _, _ in onNotesChange() }
                        .transition(.opacity)
                } else if !todo.notes.isEmpty {
                    HStack {
                        badge(for: .init(
                            text: todo.notesSummary,
                            symbol: "text.alignleft",
                            color: .secondary))
                    }
                }

                if !metadata.isEmpty {
                    metadataLine
                }
            }
            // The menu covers the row's content but stops short of the
            // checkbox, so a long press there reaches the status picker.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { menu() }

            // Only while focused: a way into the full editor. Replaces the old
            // tap-to-open, which fought the text field for the same tap.
            if isFocused {
                Button(action: onShowDetail) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.title3)
                        .foregroundStyle(todo.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Details")
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
        }
        .padding(.vertical, Theme.Metrics.rowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding * 2)
        // The focused row lifts off the list with a filled card and a tinted
        // border, so it is obvious which to-do the keyboard belongs to.
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(backgroundFill)
                .padding([.leading, .trailing], Theme.Metrics.rowHorizontalPadding)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                        .stroke(todo.color.opacity(isFocused ? 0.45 : 0), lineWidth: 1.5)
                        .padding([.leading, .trailing], Theme.Metrics.rowHorizontalPadding)
                }
                .shadow(
                    color: .black.opacity(isFocused ? 0.10 : 0),
                    radius: isFocused ? 6 : 0,
                    y: isFocused ? 2 : 0
                )
        }
        .animation(Theme.Animation.toggle, value: isFocused)
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
                    .foregroundStyle(todo.color)
            }

            // Always a live field: typing saves as it goes, and `axis:
            // .vertical` lets a long title wrap instead of running off the edge.
            // workaround for https://stackoverflow.com/questions/77388314/swiftui-textfield-with-vertical-axis-does-not-align-to-firsttextbaseline-when-te
            TextField("New TODO", text: $draftTitle, axis: .vertical)
                .opacity(0)
                .overlay {
                    // Bound to local state rather than straight to the model.
                    //
                    // Writing through `$todo.title` meant the character typed
                    // immediately before Return could be lost: `onSubmit` moved
                    // focus away in the same update pass, before SwiftUI had
                    // pushed that keystroke into the binding. Buffering here and
                    // copying to the model on change makes the text authoritative
                    // at submit time.
                    TextField("New To-Do", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focusedTodoID, equals: todo.uuid)
                        .strikethrough(todo.state == .completed)
                        .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
                        // Return is detected here rather than through
                        // `onSubmit`.
                        //
                        // `onSubmit` fires before SwiftUI has pushed the last
                        // keystroke into the binding, so moving focus from it
                        // dropped whatever character preceded Return. With
                        // `axis: .vertical` the newline arrives as ordinary
                        // text, which means by the time it is visible here
                        // every earlier character is already committed.
                        .onChange(of: draftTitle) { _, newValue in
                            guard newValue.contains("\n") else {
                                if todo.title != newValue {
                                    todo.title = newValue
                                    onTitleChange(newValue)
                                }
                                return
                            }

                            let cleaned = newValue
                                .replacingOccurrences(of: "\n", with: "")
                                .trimmingCharacters(in: .whitespaces)

                            draftTitle = cleaned
                            todo.title = cleaned
                            onTitleChange(cleaned)
                            onSubmitTitle()
                        }
                        // Pick up edits made elsewhere, such as an accepted
                        // suggestion stripping a date from the title.
                        .onChange(of: todo.title) { _, newValue in
                            if draftTitle != newValue { draftTitle = newValue }
                        }
                        .onAppear { draftTitle = todo.title }
                        .submitLabel(.next)
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
    
    private func badge(for badge: Badge) -> some View {
        Label(badge.text, systemImage: badge.symbol)
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(badge.color)
    }

    private var metadataLine: some View {
        HStack(spacing: 8) {
            ForEach(metadata, content: badge(for:))
        }
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

        if showsSpace, let space = todo.space {
            badges.append(Badge(text: space.name, symbol: space.symbolName, color: Color(hex: space.colorHex)))
        }

        return badges
    }
}


struct StatusPicker: View {
    let current: CompletionState
    let tint: Color
    let onSelect: (CompletionState) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CompletionState.allCases.filter { $0 != current }, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 20))
                            .foregroundStyle(color(for: option))
                            .frame(height: 24)

                        Text(option.label)
                            .font(.caption2)
                            .foregroundStyle(option == current ? .primary : .secondary)
                    }
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(option == current
                                  ? Color.secondary.opacity(0.16)
                                  : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option == current ? [.isSelected] : [])
            }
        }
        .padding(6)
    }

    /// Each state keeps the colour it has in the list, so the picker reads as
    /// the same vocabulary rather than a separate one.
    private func color(for option: CompletionState) -> Color {
        switch option {
        case .open: .secondary
        case .started: Theme.Palette.started
        case .completed: tint
        case .cancelled: Theme.Palette.cancelled
        }
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
            ForEach(todos.enumerated(), id: \.element) { (i, todo) in
                TodoRow(
                    todo: todo,
                    showsSpace: showsSpace,
                    isSelected: i == 0,
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
            Todo(title: "")
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
#Preview("Status picker") {
    // What the long press opens.
    StatusPicker(current: .started, tint: .blue) { _ in }
}
#endif
