import SwiftUI
import SwiftData

/// Editor for a single todo.
///
/// The title field feeds the natural-language parser; accepted suggestions set
/// the matching property and strip the phrase from the title.
struct TodoDetailView: View {
    @Bindable var todo: Todo

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query private var todos: [Todo]
    @Query private var spaces: [Space]

    @State private var suggestions: [ParsedSuggestion] = []
    @State private var isEditingNotes = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, notes }

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $todo.title, axis: .vertical)
                    .font(.title3)
                    .focused($focusedField, equals: .title)
                    .onChange(of: todo.title) { _, newValue in
                        refreshSuggestions(for: newValue)
                        store.save()
                    }

                notesEditor
            }

            Section("Schedule") {
                DateRow(
                    label: "When",
                    symbol: "calendar",
                    date: $todo.assignedDate,
                    hasTime: $todo.assignedHasTime
                ) { store.update(todo) { _ in } }

                DateRow(
                    label: "Deadline",
                    symbol: "target",
                    date: $todo.dueDate,
                    hasTime: $todo.dueHasTime
                ) { store.update(todo) { _ in } }

                DurationRow(duration: $todo.duration) { store.save() }
            }

            Section("Status") {
                Picker("Status", selection: Binding(
                    get: { todo.state },
                    set: { newState in
                        // Route through the store so the subtask rule applies
                        // here just as it does in the list.
                        if case .needsSubtaskConfirmation = store.setState(todo, to: newState) {
                            store.setStateCascading(todo, to: newState)
                        }
                    }
                )) {
                    ForEach(CompletionState.allCases, id: \.self) { state in
                        Label(state.label, systemImage: state.symbolName).tag(state)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Is a Project", isOn: Binding(
                    get: { todo.isProject },
                    set: { store.setIsProject(todo, $0) }
                ))
            }

            Section("Place") {
                Picker("Space", selection: Binding(
                    get: { todo.space?.uuid },
                    set: { id in
                        store.move(todo, toSpace: spaces.first { $0.uuid == id })
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(spaces.sorted { $0.sortIndex < $1.sortIndex }) { space in
                        Text(space.name).tag(Optional(space.uuid))
                    }
                }
            }

            subtasksSection
            RemindersSection(todo: todo)
        }
        .formStyle(.grouped)
        .navigationTitle(todo.title.isEmpty ? "New To-Do" : todo.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .suggestionBar(suggestions) { accept($0) }
        .onAppear {
            refreshSuggestions(for: todo.title)
            if todo.title.isEmpty { focusedField = .title }
        }
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
                Button(isEditingNotes ? "Preview" : "Edit") {
                    withAnimation(Theme.Animation.panel) { isEditingNotes.toggle() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if isEditingNotes || todo.notes.isEmpty {
                MarkdownSourceEditor(
                    text: $todo.notes,
                    vimBindingsEnabled: settings.vimBindingsEnabled
                )
                .frame(minHeight: 110)
                .focused($focusedField, equals: .notes)
                .onChange(of: todo.notes) { _, _ in store.save() }
            } else {
                BlockMarkdownText(markdown: todo.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.Animation.panel) { isEditingNotes = true }
                    }
            }
        }
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
            }
            .onDelete { offsets in
                for index in offsets { store.delete(todo.orderedSubtasks[index]) }
            }

            Button {
                store.addSubtask(to: todo)
            } label: {
                Label("Add Subtask", systemImage: "plus")
            }
        }
    }

    // MARK: Suggestions

    private func refreshSuggestions(for title: String) {
        var parser = TitleParser()
        // Offer only projects the todo isn't already inside.
        parser.projectNames = todos
            .filter { $0.isProject && $0.uuid != todo.uuid && $0.uuid != todo.parent?.uuid }
            .map { (name: $0.title, uuid: $0.uuid) }

        withAnimation(Theme.Animation.suggestion) {
            suggestions = parser.suggestions(for: title)
        }
    }

    /// Apply a suggestion, then clear its text from the title.
    private func accept(_ suggestion: ParsedSuggestion) {
        switch suggestion.kind {
        case .schedule(let date, let hasTime):
            todo.assignedDate = date
            todo.assignedHasTime = hasTime
        case .deadline(let date, let hasTime):
            todo.dueDate = date
            todo.dueHasTime = hasTime
        case .duration(let seconds):
            todo.duration = seconds
        case .project(_, let uuid):
            if let project = todos.first(where: { $0.uuid == uuid }) {
                store.move(todo, toParent: project)
            }
        }

        todo.title = TitleParser.removing(suggestion, from: todo.title)
        store.update(todo) { _ in }
        refreshSuggestions(for: todo.title)
    }
}

// MARK: - Rows

/// An optional date with an optional time, matching the model's split between
/// "a day" and "a day at a time".
private struct DateRow: View {
    let label: String
    let symbol: String
    @Binding var date: Date?
    @Binding var hasTime: Bool
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { date != nil },
                set: { enabled in
                    date = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                    if !enabled { hasTime = false }
                    onChange()
                }
            )) {
                Label(label, systemImage: symbol)
            }

            if date != nil {
                DatePicker(
                    "",
                    selection: Binding(get: { date ?? Date() }, set: { date = $0; onChange() }),
                    displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()

                Toggle("Include time", isOn: Binding(
                    get: { hasTime },
                    set: { hasTime = $0; onChange() }
                ))
                .font(.caption)
            }
        }
    }
}

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
