import SwiftUI
import SwiftData

/// Editor for a single todo.
///
/// The title field feeds the natural-language parser; accepted suggestions set
/// the matching property and strip the phrase from the title.
struct TodoDetailView: View {
    @Bindable var todo: Todo

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    /// Every space, in display order.
    ///
    /// Sorted by SQLite rather than re-sorted at each use site. Deliberately
    /// *not* Focus-filtered: hiding a space from the sidebar says what the user
    /// is looking at now, not where work is allowed to be filed.
    @Query(TodoQueries.allSpacesDescriptor())
    private var spaces: [Space]

    @State private var suggestionModel = TitleSuggestionModel()
    @State private var isEditingNotes = false
    /// Set while confirming deletion, which also takes any subtasks with it.
    @State private var isConfirmingDelete = false
    @State private var isAddingExistingSubtask = false
    /// Raised when completing this to-do is blocked by unfinished subtasks.
    @State private var pendingCascade: PendingCascade?
    @FocusState private var focusedField: Field?
    @FocusState private var isTitleFocused: Bool

    private enum Field { case title, notes }

    private var store: TodoStore { TodoStore(context: context) }

    /// Color the editor tints itself with, from the todo's project or space.
    private var accent: Color { todo.color }

    var body: some View {
        Form {
            Section {
                TodoTitleHeader(
                    title: $todo.title,
                    summary: headerSummary,
                    accent: accent,
                    state: todo.state,
                    onToggle: { setState(todo.toggledState) },
                    onSelectState: { setState($0) },
                    focusBinding: $isTitleFocused
                )
                .onChange(of: todo.title) { _, newValue in
                    refreshSuggestions(for: newValue)
                    store.save()
                }
            }

            Section {
                notesEditor
            }

            DateTimeSection(
                title: "Date & Time",
                date: $todo.assignedDate,
                hasTime: $todo.assignedHasTime,
                accent: accent,
                footnote: "The day this to-do is planned for."
            ) { store.update(todo) { _ in } }

            DateTimeSection(
                title: "Deadline",
                date: $todo.dueDate,
                hasTime: $todo.dueHasTime,
                accent: accent,
                footnote: "A deadline is when the work is due, separate from the day you plan to do it."
            ) { store.update(todo) { _ in } }

            Section {
                DurationRow(duration: $todo.duration) { store.save() }
            }

            Section("Status") {
                Picker("Status", selection: Binding(
                    get: { todo.state },
                    set: { setState($0) }
                )) {
                    ForEach(CompletionState.allCases, id: \.self) { state in
                        Label(state.label, systemImage: state.symbolName).tag(state)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Project", isOn: Binding(
                    get: { todo.isProject },
                    set: { store.setIsProject(todo, $0) }
                ))
            }

            // Only projects carry their own color; a plain to-do takes the
            // color of whatever contains it.
            if todo.isProject {
                Section {
                    ColorSwatchPicker(
                        selection: Binding(
                            get: { todo.colorHex },
                            set: { todo.colorHex = $0; store.save() }
                        ),
                        allowsNoColor: true
                    )
                } header: {
                    Text("Color")
                } footer: {
                    Text("Used for checkboxes and calendar blocks. Without one, the project uses its space's color.")
                }
            }

            Section("Place") {
                Picker("Space", selection: Binding(
                    get: { todo.space?.uuid },
                    set: { id in
                        store.move(todo, toSpace: spaces.first { $0.uuid == id })
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(spaces) { space in
                        Text(space.name).tag(Optional(space.uuid))
                    }
                }
            }

            subtasksSection
            RemindersSection(todo: todo)

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label(
                        todo.isProject ? "Delete Project" : "Delete To-Do",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .formStyle(.grouped)
        .tint(accent)
        // Swiping down over the form dismisses the keyboard, tracking the
        // gesture rather than snapping shut.
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(todo.title.isEmpty ? "New To-Do" : todo.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .suggestionBar(suggestionModel.suggestions) { accept($0) }
        .confirmationDialog(
            deletePrompt,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Leave the editor before the model goes away: dismissing after
                // the delete leaves this view bound to a deleted object.
                dismiss()
                store.delete(todo)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            cascadePrompt,
            isPresented: .init(
                get: { pendingCascade != nil },
                set: { if !$0 { pendingCascade = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingCascade {
                Button(pending.confirmLabel) {
                    store.setStateCascading(pending.todo, to: pending.target)
                    pendingCascade = nil
                }
                Button("Keep Subtasks", role: .cancel) { pendingCascade = nil }
            }
        }
        .sheet(isPresented: $isAddingExistingSubtask) {
            NavigationStack {
                ExistingTodoPickerView(parent: todo)
            }
        }
        .onAppear {
            refreshSuggestions(for: todo.title)
            if todo.title.isEmpty { isTitleFocused = true }
        }
        .onDisappear {
            Task {
                await todo.summarizeNotes()
            }
        }
    }

    /// Apply a state change from the header's checkbox or the status picker.
    ///
    /// Routed through the store so the subtask rule applies here as it does in
    /// the list — and, as in the list, the cascade is *asked* about rather than
    /// applied silently: completing a parent from the editor should not quietly
    /// close subtasks the user cannot see from here.
    private func setState(_ newState: CompletionState) {
        switch store.setState(todo, to: newState) {
        case .applied:
            break
        case .needsSubtaskConfirmation(let count):
            pendingCascade = PendingCascade(
                todo: todo,
                target: newState,
                blockedCount: count
            )
        }
    }

    /// Held as its own typed property rather than written inline in the dialog,
    /// which keeps an optional chain out of an already large `body`.
    private var cascadePrompt: String {
        pendingCascade?.prompt ?? ""
    }

    /// Gray context line in the header, mirroring how Calendar summarizes an
    /// event above its title field.
    private var headerSummary: String {
        let name = todo.title.isEmpty
            ? (todo.isProject ? "New Project" : "New To-Do")
            : todo.title

        guard let date = todo.assignedDate else {
            if let space = todo.space { return "\(name) in \(space.name)" }
            return "\(name) · \(todo.bucket.label)"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = todo.assignedHasTime ? "MMM d 'at' h:mm a" : "MMM d"
        return "\(name) on \(formatter.string(from: date))"
    }

    /// Spell out what a delete takes with it, since subtasks cascade.
    private var deletePrompt: String {
        let name = todo.title.isEmpty ? "this to-do" : "“\(todo.title)”"
        let count = todo.subtaskList.count

        guard count > 0 else {
            return "Delete \(name)? This cannot be undone."
        }
        return "Deleting \(name) also deletes its \(count) subtask\(count == 1 ? "" : "s"). This cannot be undone."
    }

    // MARK: Notes

    /// Notes toggle between a markdown source editor and the rendered result,
    /// so the advanced syntax the spec asks for stays both editable and
    /// readable.
    @ViewBuilder
    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(isEditingNotes ? "Done" : "Edit") {
                    if isEditingNotes {
                        isEditingNotes = false
                        focusedField = nil
                    } else {
                        beginEditingNotes()
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            // `isEditingNotes` alone decides which is shown. It deliberately
            // does not also test `todo.notes.isEmpty`: with empty notes that
            // condition is true, and typing the first character flips it,
            // swapping the editor for the preview and destroying the field the
            // user is typing in.
            if isEditingNotes {
                MarkdownSourceEditor(
                    text: $todo.notes,
                    vimBindingsEnabled: settings.vimBindingsEnabled
                )
                .frame(minHeight: 110)
                .focused($focusedField, equals: .notes)
                .onChange(of: todo.notes) { _, _ in store.save() }
            } else {
                Group {
                    if todo.notes.isEmpty {
                        Text("Add notes…")
                            .foregroundStyle(.secondary)
                    } else {
                        BlockMarkdownText(markdown: todo.notes)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginEditingNotes() }
            }
        }
    }

    /// Show the notes editor and put the cursor in it.
    ///
    /// Focus is set after the field exists in the hierarchy; setting it in the
    /// same pass that creates the field is a no-op.
    private func beginEditingNotes() {
        isEditingNotes = true
        DispatchQueue.main.async { focusedField = .notes }
    }

    // MARK: Subtasks

    @ViewBuilder
    private var subtasksSection: some View {
        Section("Subtasks") {
            ForEach(todo.orderedSubtasks) { subtask in
                HStack(spacing: 10) {
                    TodoCheckbox(
                        state: subtask.state,
                        tint: .accentColor,
                        onToggle: {
                            if case .needsSubtaskConfirmation = store.setState(subtask, to: subtask.toggledState) {
                                store.setStateCascading(subtask, to: subtask.toggledState)
                            }
                        },
                        onSelect: { newState in
                            if case .needsSubtaskConfirmation = store.setState(subtask, to: newState) {
                                store.setStateCascading(subtask, to: newState)
                            }
                        }
                    )
                    TextField("Subtask", text: Binding(
                        get: { subtask.title },
                        set: { subtask.title = $0; store.save() }
                    ))
                }
                // Removing a subtask that came from elsewhere should be able to
                // put it back rather than destroy it.
                .swipeActions(edge: .leading) {
                    Button {
                        store.detachFromParent(subtask)
                    } label: {
                        Label("Detach", systemImage: "arrow.up.forward.square")
                    }
                    .tint(.orange)
                }
            }
            .onDelete { offsets in
                for index in offsets { store.delete(todo.orderedSubtasks[index]) }
            }

            Button {
                store.addSubtask(to: todo)
            } label: {
                Label("Add Subtask", systemImage: "plus")
            }

            // Files an existing to-do here instead of creating a new one, so a
            // captured Inbox item can join a project without being retyped.
            Button {
                isAddingExistingSubtask = true
            } label: {
                Label("Add Existing To-Do…", systemImage: "text.append")
            }
        }
    }

    // MARK: Suggestions

    /// Not wrapped in `withAnimation`: this runs on every keystroke, and
    /// animating the enclosing layout from inside the field being typed into is
    /// what used to steal focus. The bar animates its own appearance instead.
    private func refreshSuggestions(for title: String) {
        suggestionModel.refresh(for: title, todo: todo, context: context)
    }

    /// Apply a suggestion, then clear its text from the title.
    private func accept(_ suggestion: ParsedSuggestion) {
        withAnimation(Theme.Animation.suggestion) {
            suggestionModel.apply(suggestion, to: todo, context: context, store: store)
        }
    }
}

// MARK: - Rows

/// Duration picker offering the common lengths plus "none".
private struct DurationRow: View {
    @Binding var duration: TimeInterval?
    let onChange: () -> Void

    private let options: [TimeInterval] = [900, 1800, 2700, 3600, 5400, 7200]

    var body: some View {
        Picker(selection: Binding(
            get: { duration },
            set: { duration = $0; onChange() }
        )) {
            Text("None").tag(TimeInterval?.none)
            ForEach(options, id: \.self) { value in
                Text(ParsedSuggestion.describe(duration: value)).tag(Optional(value))
            }
        } label: {
            Label("Duration", systemImage: "clock")
        }
    }
}

#if DEBUG
#Preview("To-do") {
    NavigationStack {
        TodoDetailView(todo: PreviewData.todo(titled: "Review"))
    }
    .previewEnvironment()
}

#Preview("Project") {
    // Projects gain the colour picker that plain to-dos do not have.
    NavigationStack {
        TodoDetailView(todo: PreviewData.project)
    }
    .previewEnvironment()
}

#Preview("Imported") {
    // Carries notes and the Reminders origin.
    NavigationStack {
        TodoDetailView(todo: PreviewData.imported)
    }
    .previewEnvironment()
}
#endif
