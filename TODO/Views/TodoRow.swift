//
//  TodoRow.swift
//  TODO
//
//  Created by John Rizkalla on 8/10/26.
//

import SwiftUI

/// One line in a todo list: checkbox, title, and a quiet row of metadata badges
/// that only appear when they carry information.
///
/// The row draws two ways. Collapsed it is read-only text; expanded — when
/// `isSelected` is true — the title and notes become live fields and a chevron
/// appears as the way into the full editor.
///
/// The row deliberately captures no taps of its own. Expanding is the *list's*
/// decision, not the row's: the list keeps one row expanded at a time and has to
/// reconcile that with its keyboard cursor, and a row that selected itself would
/// also have to fight the enclosing `List` for the same tap. So the row only
/// reports, through `onShowDetail`, the one gesture that is unambiguously its
/// own — the chevron — and the list attaches the tap that selects a row.
struct TodoRow : View {
    var todo: Todo
    let showsSpace: Bool
    /// True when this is the row the list has expanded for editing.
    ///
    /// Distinct from the detail view being open on it: expanding a row is the
    /// first stage of the two-stage tap, and the editor is the second.
    let isSelected: Bool
    var onToggle: (Todo) -> Void
    var onSelectState: (CompletionState) -> Void
    var onTitleChange: (String) -> Void
    var onNotesChange: (Todo) -> Void
    var menu: () -> AnyView
    var onSubmitTitle: () -> Void
    var onShowDetail : (Todo) -> Void
    /// Opens the recurrence panel for this row.
    ///
    /// Optional so the previews and any surface without a panel to present can
    /// leave the chip inert rather than having to fake one.
    var onEditRecurrence: ((Todo) -> Void)?

    /// Which row's title currently holds focus, keyed by todo id.
    ///
    /// Owned by the list rather than the row, because the list is what acts on
    /// it: creating a to-do focuses its title, leaving a row that was never
    /// given one discards it, and the suggestion chips follow whichever title
    /// is being typed into. A row keeping its own title focus would leave all
    /// three with nothing to observe.
    @FocusState.Binding var focusedTodoID: UUID?

    @State var todoTitle = ""
    @State var todoDescription = ""

    /// The notes field's focus, which stays local: nothing outside the row
    /// needs to know the caret moved from the title to the notes.
    @FocusState var isDescriptionFocused: Bool

    /// True when this row's title holds the keyboard.
    private var isTitleFocused: Bool { focusedTodoID == todo.uuid }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                TodoCheckbox(
                    state: todo.state,
                    tint: todo.color,
                    onToggle: { onToggle(todo) },
                    onSelect: onSelectState
                ).padding([.top], isSelected ? 3 : 0) // TODO: Tune for macos?
                
                VStack(alignment: .leading) {
                    // The title is one view in both states rather than a field
                    // swapped for a label. Two branches of an `if` are separate
                    // views to SwiftUI, so it cross-fades between them — which
                    // is the flicker the expand animation used to have, and no
                    // amount of tuning the animation curve removes it. A single
                    // field that is merely disabled while collapsed has nothing
                    // to fade between, so the row only changes height.
                    if isSelected {
                        TextField("TODO title", text: $todoTitle, axis: .vertical)
                            .focused($focusedTodoID, equals: todo.uuid)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Return commits the field on macOS rather than
                        // inserting a newline, so it arrives here and never as
                        // text. `onChange(of: todoTitle)` below covers the
                        // other half — on iOS the same vertical field inserts a
                        // newline instead and never submits. Both routes end in
                        // `submitTitle()`, which is why the two platforms
                        // behave the same despite disagreeing about the key.
                        //
                        // The keystroke `onSubmit` was once suspected of
                        // dropping is safe now: this reads `todoTitle`, which
                        // SwiftUI has already updated, and the list defers
                        // creating the next row by a runloop turn anyway.
                            .onSubmit(submitTitle)
                            .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
                            .strikethrough(todo.state == .completed)
                    } else {
                        Text((try? AttributedString(markdown: todo.title)) ?? .init(todo.title))
                            .lineLimit(1...6)
                            .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
                            .strikethrough(todo.state == .completed)
                    }

                    statusLine

                    // The schedule summary, revealed with the row.
                    //
                    // Clipped to zero height rather than inserted by an `if`,
                    // for the same reason the notes field below is: a view
                    // added on expansion fades in out of step with the row's
                    // growth, and this one sits between two things that are
                    // already animating.
                    recurrenceChip
                        .frame(height: isSelected ? nil : 0, alignment: .top)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .clipped()

                    // Grows out of nothing rather than being inserted.
                    //
                    // Mounted at all times and clipped to a zero height when
                    // collapsed: a field added by an `if` animates by fading,
                    // and it would also tear the field out of the hierarchy the
                    // moment focus left it, so a tap aimed at the notes could
                    // land on a view that no longer exists.
                    TextField("TODO description", text: $todoDescription, axis: .vertical)
                        .focused($isDescriptionFocused)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: isSelected ? nil : 0, alignment: .top)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())

                // Only while expanded: the way into the full editor. A real
                // button rather than a tap gesture, so it keeps its hit area
                // and accessibility action inside the enclosing `List`.
                //
                // Scaled out from its trailing edge rather than inserted, so it
                // arrives with the row's own growth instead of blinking in.
                Button { onShowDetail(todo) } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(todo.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Details")
                .frame(width: isSelected ? nil : 0)
                .frame(height: isSelected ? nil : 0)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .clipped()
            }
        }
        // Pinned to the top so the extra height all appears below the title.
        //
        // Without an explicit alignment the row grows from its centre, which
        // pushes the title up by half the notes' height as it expands and reads
        // as the row jumping rather than opening.
        .frame(maxWidth: .infinity, alignment: .top)
        .contextMenu {
            menu()
        }
        .padding([.leading, .trailing], 7)
        .padding([.top, .bottom], isSelected ? 8 : 1)
        // Clipping is what turns the height change into a reveal: the notes
        // field is full-size throughout and simply spends the animation outside
        // the row's bounds, so the text slides into view instead of stretching.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(borderOverlay)
        // One animation for every part of the expansion — height, card, border,
        // and chevron — so they arrive together rather than in two waves.
        .animation(Theme.Animation.rowExpand, value: isSelected)
        .background {
            // Always mounted and faded by opacity rather than swapped for an
            // `EmptyView`: the card has to resize *with* the row, and a
            // background inserted by an `if` starts life at the row's final
            // height instead of growing into it.
            //
            // Drawn in the *background* colour rather than white: on a dark
            // appearance a hardcoded white card puts white text on a white
            // field.
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                .fill(Color.rowCard)
                .shadow(
                    color: .black.opacity(Theme.Metrics.rowShadowOpacity),
                    radius: Theme.Metrics.rowShadowRadius,
                    y: Theme.Metrics.rowShadowOffset
                )
                .shadow(
                    color: todo.color.opacity(0.1),
                    radius: Theme.Metrics.rowShadowRadius / 2
                )
                .opacity(isSelected ? 1 : 0)
        }
        .onAppear {
            todoTitle = todo.title
            todoDescription = todo.notes
        }
        // Pick up edits made elsewhere — an accepted suggestion stripping a
        // date out of the title, or the detail editor rewriting the notes.
        //
        // Deliberately *not* gated on the field being unfocused. Accepting a
        // chip is the main case this exists for, and the chips are only ever on
        // screen while the title has the caret — so a `!isTitleFocused` guard
        // here skipped precisely the rewrite it was written to deliver, leaving
        // "today" in the field after the user had scheduled it. The stale local
        // copy then won the next keystroke and put the phrase back.
        //
        // What the guard was protecting against is the echo of the user's own
        // typing: `todoTitle` is written through to `todo.title` below, which
        // re-enters here. Comparing against `todoTitle` is enough to tell the
        // two apart — an echo already matches and is dropped, while a rewrite
        // from elsewhere differs and is adopted.
        .onChange(of: todo.title) { _, newValue in
            guard todoTitle != newValue else { return }
            todoTitle = newValue
        }
        .onChange(of: todo.notes) { _, newValue in
            guard !isDescriptionFocused, todoDescription != newValue else { return }
            todoDescription = newValue
        }
        // Collapsing the row takes the keyboard with it, so it is never left
        // in a to-do the user has moved on from.
        .onChange(of: isSelected) { oldValue, newValue in
            guard oldValue && !newValue else { return }
            if isTitleFocused { focusedTodoID = nil }
            isDescriptionFocused = false
        }
        // Written through as the user types rather than on blur: the list
        // debounces the save behind these, and the suggestion chips are drawn
        // from the title as it stands right now.
        .onChange(of: todoTitle) { _, newValue in
            // A newline reaching the binding means Return arrived as text
            // rather than as a key — the iOS vertical field, and paste or
            // dictation on any platform. `onKeyPress` above has already
            // handled the ordinary macOS case.
            guard newValue.contains("\n") else {
                guard todo.title != newValue else { return }
                todo.title = newValue
                onTitleChange(newValue)
                return
            }
            submitTitle()
        }
        .onChange(of: todoDescription) { _, newValue in
            guard todo.notes != newValue else { return }
            todo.notes = newValue
            onNotesChange(todo)
        }
    }
    
    /// Commit the title and ask the list for the next to-do.
    ///
    /// Shared by both routes Return can take — the key press, and a newline
    /// landing in the binding — so the two cannot drift into behaving
    /// differently. Stripping the newline matters for the second: leaving it in
    /// would persist a title with a trailing blank line.
    private func submitTitle() {
        let cleaned = todoTitle
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)

        todoTitle = cleaned
        if todo.title != cleaned { todo.title = cleaned }
        onTitleChange(cleaned)
        onSubmitTitle()
    }

    /// The expanded row's tinted border.
    ///
    /// Faded rather than inserted, for the same reason as the card behind it:
    /// it has to trace the row's edge the whole way out, not appear once the
    /// row has finished growing.
    var borderOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
            .strokeBorder(todo.color)
            .opacity(isSelected ? 1 : 0)
    }
    
    private struct Badge: Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
        let color: Color
    }

    /// Only the fields that are actually set produce a badge, keeping rows
    /// uncluttered.
    private var badges: [Badge] {
        var badges: [Badge] = []

        // The recurring glyph goes first, before the dates it qualifies: this
        // row's date is one occurrence of a series rather than a one-off, and
        // reading "today" before learning that would be reading it wrong.
        if todo.isRecurring {
            badges.append(Badge(
                text: "",
                symbol: recurrenceSymbol,
                color: todo.isDormantRecurrenceTemplate ? .orange : .secondary
            ))
        }
        
        if let date = todo.assignedDate ?? todo.dueDate, date < Date() && !Calendar.current.isDateInToday(date) && todo.state != .completed {
            badges.append(.init(
                text: "Overdue",
                symbol: "exclamationmark.triangle",
                color: .red
            ))
        }

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
    
    /// A paused series is drawn as a pause glyph rather than the cycling arrows.
    ///
    /// The distinction matters at a glance: the arrows say "this comes back",
    /// and on a template that is exactly what is *not* happening right now.
    private var recurrenceSymbol: String {
        guard let rule = todo.effectiveRecurrenceRule else {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        switch rule.status {
        case .active: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .paused: return "pause.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    /// The clickable summary of the schedule, shown only while expanded.
    ///
    /// Text rather than a full control, per the spec: it reads as a sentence
    /// ("every Monday at 3 PM") and only reveals itself as tappable by being
    /// tinted. A button-shaped control here would compete with the checkbox and
    /// the chevron for a row that is mostly text.
    @ViewBuilder
    private var recurrenceChip: some View {
        if let rule = todo.effectiveRecurrenceRule {
            Button {
                onEditRecurrence?(todo)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: recurrenceSymbol)
                        .font(.caption2)
                    Text(rule.summary)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(rule.status.generatesInstances ? Color.accentColor : .orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(
                        (rule.status.generatesInstances ? Color.accentColor : .orange)
                            .opacity(0.12)
                    )
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(onEditRecurrence == nil)
            .accessibilityLabel("Repeats \(rule.summary). Edit schedule")
        }
    }

    /// The "this is a schedule, not a task" marker on a dormant template.
    ///
    /// The spec asks a paused series to be visibly not a real to-do. Without
    /// this it is indistinguishable from an ordinary Anytime item, and ticking
    /// its checkbox would look like completing work that was never scheduled.
    @ViewBuilder
    private var templateMarker: some View {
        if todo.isDormantRecurrenceTemplate {
            Text(todo.effectiveRecurrenceRule?.status == .cancelled ? "Cancelled series" : "Paused series")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    var statusLine: some View {
        HStack {
            templateMarker

            ForEach(badges) { badge in
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol)
                        .foregroundStyle(badge.color.opacity(0.85))
                        .font(.footnote)
                    // A glyph-only badge — the recurring marker — carries no
                    // text, and an empty `Text` would still claim spacing.
                    if !badge.text.isEmpty {
                        Text(badge.text)
                            .foregroundStyle(Color.secondary)
                            .font(.footnote)
                    }
                }
            }
        }
        .padding([.top], 1)
    }
}


#if DEBUG

/// Owns the expansion state and the tap that drives it, the way the real list
/// does — the row itself captures neither.
struct TodoRowHost : View {

    var todos: [Todo]

    @State var expandedTodo: Todo?
    @FocusState private var focusedTodoID: UUID?

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(todos) { todo in
                TodoRow(
                    todo: todo,
                    showsSpace: true,
                    isSelected: expandedTodo?.uuid == todo.uuid,
                    onToggle: { todo in
                        switch todo.state {
                        case .open, .cancelled, .started:
                            todo.state = .completed
                        case .completed:
                            todo.state = .open
                        }
                    },
                    onSelectState: { _ in
                        print("state changed")
                    },
                    onTitleChange: {
                        print("Title changed: \($0)")
                    }, onNotesChange: {
                        print("Notes changed: \($0.notes)")
                    }, menu: {
                        AnyView(EmptyView())
                    },
                    onSubmitTitle: {},
                    onShowDetail: { print("Show detail: \($0.title)") },
                    focusedTodoID: $focusedTodoID
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard expandedTodo?.uuid != todo.uuid else { return }
                    withAnimation(Theme.Animation.rowExpand) { expandedTodo = todo }
                }
            }
            Spacer()
        }
        .padding([.top], 30)
        .padding([.leading, .trailing])
    }
}

#Preview {
    let focused = PreviewData.todo(titled: "Renew passport")
    TodoRowHost(
        todos: [
            PreviewData.todo(titled: "Review"),
            PreviewData.todo(titled: "Standup"),
            PreviewData.todo(titled: "Pay the"),
            focused,

            PreviewData.project,
            PreviewData.imported,
        ],
        expandedTodo: focused
    )
    .previewEnvironment()
}

#endif
