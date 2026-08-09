import SwiftUI
import SwiftData

/// Choose todos that already exist and attach them to `parent` as subtasks.
///
/// The app could previously only create a *new* subtask, so an item captured in
/// the Inbox had to be retyped to become part of a project. This moves the
/// existing todo instead, keeping its notes, dates, and reminders.
///
/// Selection is multiple, since filing a backlog into a project is usually
/// several items at once.
struct ExistingTodoPickerView: View {
    let parent: Todo

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var todos: [Todo]

    @State private var query = ""
    @State private var selected: Set<UUID> = []

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        List {
            if candidates.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.todos) { todo in
                            row(todo)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search to-dos")
        .navigationTitle("Add Existing")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") {
                    commit()
                }
                .disabled(selected.isEmpty)
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: Rows

    private func row(_ todo: Todo) -> some View {
        let isSelected = selected.contains(todo.uuid)

        return Button {
            withAnimation(Theme.Animation.toggle) {
                if isSelected {
                    selected.remove(todo.uuid)
                } else {
                    selected.insert(todo.uuid)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    InlineMarkdownText(
                        markdown: todo.title.isEmpty ? "Untitled" : todo.title
                    )
                    .foregroundStyle(.primary)

                    if let subtitle = subtitle(for: todo) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            query.isEmpty ? "Nothing to Add" : "No Matches",
            systemImage: query.isEmpty ? "tray" : "magnifyingglass",
            description: Text(
                query.isEmpty
                    ? "Every other to-do is already here, or is a project."
                    : "No to-do matches “\(query)”."
            )
        )
    }

    /// Where the todo currently lives, so the user can tell two similarly named
    /// items apart before moving one.
    private func subtitle(for todo: Todo) -> String? {
        var parts: [String] = []

        if let existingParent = todo.parent {
            parts.append("in \(existingParent.title.isEmpty ? "a to-do" : existingParent.title)")
        } else if let space = todo.space {
            parts.append("in \(space.name)")
        } else {
            parts.append(todo.bucket.label)
        }

        if let assigned = todo.assignedDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append(formatter.string(from: assigned))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Data

    /// Todos eligible to become subtasks of `parent`.
    ///
    /// `canAdopt` filters out the parent itself, its ancestors, anything
    /// already attached, and projects.
    private var candidates: [Todo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        return todos
            .filter { parent.canAdopt($0) }
            // A resolved to-do is history; adding one to a project is almost
            // always a mistake, so they stay out unless searched for by name.
            .filter { !$0.state.isResolved || !trimmed.isEmpty }
            .filter {
                trimmed.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private struct Group {
        let title: String
        let todos: [Todo]
    }

    /// Split into unfiled and filed, so items already living somewhere are
    /// clearly marked as a move rather than a simple add.
    private var groups: [Group] {
        let all = candidates
        let unfiled = all.filter { $0.parent == nil && $0.space == nil }
        let filed = all.filter { $0.parent != nil || $0.space != nil }

        return [
            Group(title: "Inbox & Unfiled", todos: unfiled),
            Group(title: "Filed Elsewhere", todos: filed),
        ].filter { !$0.todos.isEmpty }
    }

    private func commit() {
        // Resolve against the full list rather than `candidates`, which the
        // search field may currently be narrowing.
        for todo in todos where selected.contains(todo.uuid) {
            store.adopt(todo, asSubtaskOf: parent)
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Add existing") {
    NavigationStack {
        ExistingTodoPickerView(parent: PreviewData.project)
    }
    .previewEnvironment()
}
#endif
