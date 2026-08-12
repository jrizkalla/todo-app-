#if os(macOS)
import SwiftUI
import SwiftData

/// The macOS editor: a dense, Calendar-style card rather than a full-page form.
///
/// The stock Calendar app's event popover is the model. It fits a title, a
/// location line, an aligned block of date and repeat fields, invitees, and
/// notes into a few hundred points — by dropping the grouped-form chrome, using
/// a label column instead of a section header per field, and showing only the
/// controls a field actually needs. This view applies the same treatment to a
/// to-do, which has the same shape: a name, a color, a schedule, and some text.
///
/// It is deliberately a separate view from `TodoDetailView` rather than a pile
/// of `#if os(macOS)` inside it. The two differ in nearly every row — Reminders'
/// tinted icon tiles and inline graphical pickers are right for a touch screen
/// and far too tall for a popover — so sharing the body would mean branching it
/// almost line by line.
struct TodoDetailCompactView: View {
    @Bindable var todo: Todo

    /// Shown as a "open in its own window" affordance when the host can do it.
    /// Nil in a window, which is already torn off.
    var onTearOff: (() -> Void)?
    /// Closes the popover. Nil in a window, which has its own close button.
    var onClose: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    /// Every space, in display order.
    ///
    /// Sorted by SQLite rather than re-sorted at each use site. Deliberately
    /// *not* Focus-filtered: hiding a space from the sidebar says what the user
    /// is looking at now, not where work is allowed to be filed.
    @Query(TodoQueries.allSpacesDescriptor())
    private var spaces: [Space]

    @State private var suggestionModel = TitleSuggestionModel()
    @State private var isConfirmingDelete = false
    @State private var isEditingNotes = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, notes }

    private var store: TodoStore { TodoStore(context: context) }
    private var accent: Color { todo.color }

    /// Width of the label column. Every row hangs its control off the same
    /// gutter, which is what makes the block read as a table rather than as a
    /// stack of unrelated controls.
    private let labelWidth: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scheduleCard
                    statusCard
                    notesCard
                    subtasksCard
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .frame(minHeight: 320, maxHeight: 560)
        .tint(accent)
        .suggestionBar(suggestionModel.suggestions) { suggestion in
            withAnimation(Theme.Animation.suggestion) {
                _ = suggestionModel.apply(suggestion, to: todo, context: context, store: store)
            }
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Leave before the model goes away, so this view is never bound
                // to a deleted object.
                onClose?()
                store.delete(todo)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { suggestionModel.refresh(for: todo.title, todo: todo, context: context) }
        .onDisappear { Task { await todo.summarizeNotes() } }
    }

    // MARK: Header

    /// Title, color, and the window controls — Calendar's popover puts the same
    /// three things on its top line.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(accent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                TextField("New To-Do", text: $todo.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .title)
                    .onChange(of: todo.title) { _, newValue in
                        suggestionModel.refresh(for: newValue, todo: todo, context: context)
                        store.save()
                    }

                Text(contextLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let onTearOff {
                Button(action: onTearOff) {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Open in a new window")
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The gray line under the title: where this to-do lives, and when.
    private var contextLine: String {
        var parts: [String] = []
        if let space = todo.space { parts.append(space.name) }
        else if let parent = todo.parent { parts.append(parent.title) }
        else { parts.append(todo.bucket.label) }

        if let date = todo.assignedDate {
            parts.append(ParsedSuggestion.describe(date, hasTime: todo.assignedHasTime))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Cards

    /// Dates and duration, in the aligned label/value block Calendar uses.
    private var scheduleCard: some View {
        card {
            CompactDateRow(
                label: "Starts",
                date: $todo.assignedDate,
                hasTime: $todo.assignedHasTime,
                labelWidth: labelWidth
            ) { store.update(todo) { _ in } }

            Divider()

            CompactDateRow(
                label: "Due",
                date: $todo.dueDate,
                hasTime: $todo.dueHasTime,
                labelWidth: labelWidth
            ) { store.update(todo) { _ in } }

            Divider()

            row("Duration") {
                Picker("", selection: Binding(
                    get: { todo.duration },
                    set: { todo.duration = $0; store.save() }
                )) {
                    Text("None").tag(TimeInterval?.none)
                    ForEach([900.0, 1800.0, 2700.0, 3600.0, 5400.0, 7200.0], id: \.self) { value in
                        Text(ParsedSuggestion.describe(duration: value)).tag(Optional(value))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var statusCard: some View {
        card {
            row("Status") {
                Picker("", selection: Binding(
                    get: { todo.state },
                    set: { newState in
                        if case .needsSubtaskConfirmation = store.setState(todo, to: newState) {
                            store.setStateCascading(todo, to: newState)
                        }
                    }
                )) {
                    ForEach(CompletionState.allCases, id: \.self) { state in
                        Label(state.label, systemImage: state.symbolName).tag(state)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Divider()

            row("Space") {
                Picker("", selection: Binding(
                    get: { todo.space?.uuid },
                    set: { id in store.move(todo, toSpace: spaces.first { $0.uuid == id }) }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(spaces) { space in
                        Text(space.name).tag(Optional(space.uuid))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Divider()

            row("Project") {
                Toggle("", isOn: Binding(
                    get: { todo.isProject },
                    set: { store.setIsProject(todo, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer(minLength: 0)
            }

            // Only a project carries its own color; anything else inherits.
            if todo.isProject {
                Divider()
                row("Color") {
                    ColorSwatchPicker(
                        selection: Binding(
                            get: { todo.colorHex },
                            set: { todo.colorHex = $0; store.save() }
                        ),
                        allowsNoColor: true
                    )
                }
            }
        }
    }

    /// Notes, editable in place. Unlike the iOS editor there is no Edit button:
    /// a click into the text is the edit gesture on a Mac.
    private var notesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isEditingNotes {
                    MarkdownSourceEditor(
                        text: $todo.notes,
                        vimBindingsEnabled: settings.vimBindingsEnabled
                    )
                    .frame(height: 90)
                    .focused($focusedField, equals: .notes)
                    .onChange(of: todo.notes) { _, _ in store.save() }
                } else {
                    Group {
                        if todo.notes.isEmpty {
                            Text("Add notes…").foregroundStyle(.tertiary)
                        } else {
                            BlockMarkdownText(markdown: todo.notes)
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isEditingNotes = true
                        DispatchQueue.main.async { focusedField = .notes }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtasksCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Subtasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.addSubtask(to: todo)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add subtask")
                }

                if todo.orderedSubtasks.isEmpty {
                    Text("None")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(todo.orderedSubtasks) { subtask in
                        HStack(spacing: 8) {
                            TodoCheckbox(
                                state: subtask.state,
                                tint: accent,
                                onToggle: {
                                    if case .needsSubtaskConfirmation = store.setState(subtask, to: subtask.toggledState) {
                                        store.setStateCascading(subtask, to: subtask.toggledState)
                                    }
                                },
                                onSelect: { newState in
                                    if case .needsSubtaskConfirmation = store.setState(subtask, to: newState) {
                                        store.setStateCascading(subtask, to: newState)
                                    }
                                },
                                scale: .compact
                            )
                            TextField("Subtask", text: Binding(
                                get: { subtask.title },
                                set: { subtask.title = $0; store.save() }
                            ))
                            .textFieldStyle(.plain)
                            .font(.callout)

                            Button {
                                store.delete(subtask)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(todo.isProject ? "Delete project" : "Delete to-do")

            Spacer()

            if todo.importedFromReminders {
                Label("Imported", systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Building blocks

    /// A grouped block, standing in for a `Form` section without its height.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    /// One label/control line sharing the block's label gutter.
    private func row<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private var deletePrompt: String {
        let name = todo.title.isEmpty ? "this to-do" : "“\(todo.title)”"
        let count = todo.subtaskList.count
        guard count > 0 else { return "Delete \(name)? This cannot be undone." }
        return "Deleting \(name) also deletes its \(count) subtask\(count == 1 ? "" : "s"). This cannot be undone."
    }
}

// MARK: - Date row

/// A date field in Calendar's popover style: a checkbox to enable it and, when
/// on, compact date and time fields on one line.
///
/// `DatePicker` with `.field` style is the whole point — the graphical month
/// grid the iOS editor expands inline is several hundred points tall, which is
/// what made the detail view unusable as a popover.
private struct CompactDateRow: View {
    let label: String
    @Binding var date: Date?
    @Binding var hasTime: Bool
    let labelWidth: CGFloat
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { date != nil },
                set: { enabled in
                    date = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                    if !enabled { hasTime = false }
                    onChange()
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            if date != nil {
                DatePicker(
                    "",
                    selection: bound,
                    displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                .datePickerStyle(.field)

                Toggle(isOn: Binding(
                    get: { hasTime },
                    set: { hasTime = $0; onChange() }
                )) {
                    Image(systemName: "clock")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Include a time")
            }

            Spacer(minLength: 0)
        }
    }

    private var bound: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { date = $0; onChange() }
        )
    }
}

#if DEBUG
#Preview("Compact detail") {
    TodoDetailCompactView(todo: PreviewData.todo(titled: "Review"), onTearOff: {}, onClose: {})
        .previewEnvironment()
}

#Preview("Project") {
    TodoDetailCompactView(todo: PreviewData.project, onTearOff: {}, onClose: {})
        .previewEnvironment()
}
#endif

#endif
