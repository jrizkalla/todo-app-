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

    /// Keeps the row expanded across the gap between its two fields.
    ///
    /// Moving from the title to the notes blurs the title one runloop turn
    /// before the notes field takes focus, so for that turn *neither* is
    /// focused. Reading the row as collapsed on that transient tore the notes
    /// field out of the hierarchy before the click could land on it — which is
    /// why notes could not be reached at all.
    ///
    /// The latch holds the expanded state through the gap; `syncExpansion()`
    /// clears it a turn later, once focus has settled somewhere real.
    @State private var isExpanded = false

    /// True when either of this row's fields holds the keyboard right now.
    private var hasFieldFocus: Bool {
        focusedTodoID == todo.uuid || focusedField != nil
    }

    /// True when the row should draw in its expanded form.
    ///
    /// The selected row counts as expanded too. On macOS the editor opens in a
    /// popover anchored to the row, and a row that collapsed the moment its
    /// popover took the keyboard would shift the popover's own anchor out from
    /// under it.
    private var isFocused: Bool {
        hasFieldFocus || isExpanded || isSelected
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

    /// Sizes and fonts for this surface. See `Theme.RowScale`.
    private let scale = Theme.RowScale.regular

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.horizontalSpacing) {
            TodoCheckbox(
                state: todo.state,
                tint: todo.color,
                onToggle: onToggle,
                onSelect: onSelectState,
                scale: scale
            )
            // Nudge the box onto the text's optical baseline.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            VStack(alignment: .leading, spacing: 3) {
                titleLine

                // Focused rows expand to expose notes inline, so a quick
                // thought can be captured without leaving the list. Collapsed
                // rows show only a summary badge.
                //
                // The field is *always mounted* and hidden with a zero frame
                // when collapsed, rather than being added and removed by an
                // `if`. Mounting it conditionally is what made the notes
                // unreachable: clicking the field blurs the title, which
                // collapses the row, which tears the field out of the hierarchy
                // in the same pass — so the click that was meant to focus it
                // never lands on anything. A field that is always present has
                // nothing to tear down, so the click reaches it.
                notesField
                    .frame(height: isFocused ? nil : 0)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(isFocused)
                    .accessibilityHidden(!isFocused)

                if !isFocused && !todo.notes.isEmpty {
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
        .padding(.vertical, Theme.Metrics.listRowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.listRowHorizontalPadding)
        // The focused row lifts off the list with a filled card and a tinted
        // border, so it is obvious which to-do the keyboard belongs to.
        //
        // The card insets by `listRowCardInset`, which is derived from the same
        // constant the content is padded by. Hard-coding a different value here
        // is what put the card's edge in the wrong place relative to the text
        // once the two platforms stopped sharing one padding number.
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(backgroundFill)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                        .stroke(todo.color.opacity(isFocused ? 0.45 : 0), lineWidth: 1.5)
                }
                .padding([.leading, .trailing], Theme.Metrics.listRowCardInset)
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
        // Either field gaining focus expands the row; losing it collapses the
        // row only if the other field has not picked focus up by the next turn.
        .onChange(of: hasFieldFocus) { _, hasFocus in
            if hasFocus {
                // Unanimated on the way in. Focus arriving here often means it
                // just left this row's *other* field, and animating that
                // re-entry is what read as the row flickering out and back.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded = true }
            } else {
                syncExpansion()
            }
        }
    }

    /// Collapse the row a runloop turn after it lost focus, unless focus landed
    /// back on one of its own fields in the meantime.
    ///
    /// The delay is the whole point: moving between the title and the notes
    /// passes through a turn where neither is focused, and that transient must
    /// not read as "the user left this row".
    private func syncExpansion() {
        DispatchQueue.main.async {
            guard !hasFieldFocus else { return }
            isExpanded = false
        }
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

            // On iOS the field is drawn twice: an invisible copy establishes the
            // row's baseline, because a `TextField` with `axis: .vertical` does
            // not align to `.firstTextBaseline` on its own, and the real field
            // is overlaid on it. See
            // https://stackoverflow.com/questions/77388314
            //
            // AppKit does not have that bug, and the duplicate is not free: it
            // is a second live text field per row, instantiated for every row on
            // screen. Building two of them per row is a large part of what made
            // clicking a task on a Mac feel slow, so macOS renders the field
            // once.
            #if os(macOS)
            titleField
            #else
            TextField("New TODO", text: $draftTitle, axis: .vertical)
                .font(scale.titleFont)
                .opacity(0)
                .overlay { titleField }
            #endif

            // Marks a todo pulled in from the system Reminders app.
            if todo.importedFromReminders {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Imported from Reminders")
            }
        }
    }
    
    /// Inline notes, for capturing a thought without opening the editor.
    ///
    /// Stretched to the row's full width so a click anywhere on the line lands
    /// on the field. A `TextField` is only as wide as its text, and on a Mac —
    /// where there is no keyboard to aim at — clicking the empty space to the
    /// right of a short note otherwise missed it entirely.
    private var notesField: some View {
        TextField("Notes", text: $todo.notes, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(1...4)
            .foregroundStyle(.secondary)
            .focused($focusedField, equals: .notes)
            .onChange(of: todo.notes) { _, _ in onNotesChange() }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The notes line needs its own catcher for the same reason the
            // title does — see there. Without one, a click beside a short note
            // fell through to the title's catcher sitting behind it, which
            // moved focus to the title and collapsed the row.
            #if os(macOS)
            .overlay {
                ClickCatcher { focusedField = .notes }
                    .opacity(focusedField == .notes ? 0 : 1)
                    .allowsHitTesting(focusedField != .notes)
            }
            #endif
    }

    /// The editable title.
    ///
    /// Bound to local state rather than straight to the model. Writing through
    /// `$todo.title` meant the character typed immediately before Return could
    /// be lost: `onSubmit` moved focus away in the same update pass, before
    /// SwiftUI had pushed that keystroke into the binding. Buffering here and
    /// copying to the model on change makes the text authoritative at submit
    /// time.
    private var titleField: some View {
        TextField("New To-Do", text: $draftTitle, axis: .vertical)
            .textFieldStyle(.plain)
            .font(scale.titleFont)
            .lineLimit(1...6)
            .focused($focusedTodoID, equals: todo.uuid)
            .strikethrough(todo.state == .completed)
            .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
            // Return is detected here rather than through `onSubmit`.
            //
            // `onSubmit` fires before SwiftUI has pushed the last keystroke into
            // the binding, so moving focus from it dropped whatever character
            // preceded Return. With `axis: .vertical` the newline arrives as
            // ordinary text, which means by the time it is visible here every
            // earlier character is already committed.
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
            // Pick up edits made elsewhere, such as an accepted suggestion
            // stripping a date from the title.
            .onChange(of: todo.title) { _, newValue in
                if draftTitle != newValue { draftTitle = newValue }
            }
            .onAppear { draftTitle = todo.title }
            .submitLabel(.next)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Drops the focus ring, which would otherwise draw a second box
            // inside the row's own focus card.
            //
            // The white editing background that AppKit puts behind the text
            // while the field is first responder is deliberately left alone. It
            // is the shared field editor, installed at focus time and above
            // anything SwiftUI can place, so removing it means replacing the
            // whole field with an `NSViewRepresentable` — not worth the risk to
            // the title-editing behaviour for a background that only shows on
            // the one row being edited.
            #if os(macOS)
            .focusEffectDisabled()
            // Makes the dead space beside the text clickable.
            //
            // A `TextField` accepts clicks only where its glyphs are — widening
            // its SwiftUI frame does not widen the field's hit area — and the
            // enclosing `List` claims everything else for row selection. So on
            // a Mac, clicking to the right of a short title did nothing at all.
            // This overlay sits in front, ahead of the List's own handling, and
            // hands focus to the field.
            .overlay {
                ClickCatcher { focusedTodoID = todo.uuid }
                    // Uncovers the field once it is being edited, so
                    // click-to-position-caret and drag-to-select keep working.
                    .opacity(focusedTodoID == todo.uuid ? 0 : 1)
                    .allowsHitTesting(focusedTodoID != todo.uuid)
            }
            #endif
    }

    private func badge(for badge: Badge) -> some View {
        Label(badge.text, systemImage: badge.symbol)
            .font(scale.metadataFont)
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


#if os(macOS)
/// A transparent AppKit view that turns a click into a callback.
///
/// SwiftUI's own gestures lose this fight: inside a `List`, AppKit's row view
/// handles the mouse-down for selection before a `TapGesture` — even a
/// `simultaneousGesture` — is consulted, so a click on the empty space beside a
/// row's text is simply swallowed. An `NSView` that implements `mouseDown`
/// sits in the responder chain itself and gets the event first.
private struct ClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ClickView)?.onClick = onClick
    }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?()

            // Drop the select-all that comes with being focused
            // programmatically, and leave the caret at the end instead.
            //
            // A field focused by a real click places the caret where the user
            // clicked; one focused through a `@FocusState` binding selects its
            // whole contents, so the very next keystroke replaces the note
            // instead of extending it. Collapsing the selection to the end is
            // the behaviour a click into trailing empty space implies anyway.
            DispatchQueue.main.async { [weak self] in
                guard let editor = self?.window?.firstResponder as? NSText else { return }
                editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
            }
        }

        /// Keeps the I-beam over the area, so it still reads as editable text.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
}
#endif

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
                        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
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
