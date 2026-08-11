import SwiftUI
import SwiftData

/// Type-to-filter picker for refiling a to-do, opened with Cmd+M.
///
/// Spaces and projects are listed together and filtered by one field, because
/// from the keyboard "where does this go" is a single question — making the
/// user first choose *which kind* of destination they mean would be a step that
/// exists only because of how the data is modelled.
struct MoveDestinationView: View {
    let todo: Todo
    let onPick: (Destination) -> Void
    let onDismiss: () -> Void

    /// Somewhere a to-do can be filed.
    enum Destination: Identifiable, Equatable {
        case none
        case space(UUID)
        case project(UUID)

        var id: String {
            switch self {
            case .none: "none"
            case .space(let id): "space-\(id)"
            case .project(let id): "project-\(id)"
            }
        }
    }

    @Query private var spaces: [Space]
    @Query private var todos: [Todo]

    @State private var query = ""
    /// Which row Return will pick.
    @State private var highlighted: Destination?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField

            Divider()

            if options.isEmpty {
                Text("No matching space or project")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                optionList
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .onAppear {
            isFieldFocused = true
            highlighted = options.first
        }
        // The highlight has to stay on something that still passes the filter,
        // or Return commits to a row the user can no longer see.
        .onChange(of: query) { _, _ in
            if let highlighted, options.contains(highlighted) { return }
            highlighted = options.first
        }
    }

    private var header: some View {
        HStack {
            Text("Move To")
                .font(.headline)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Space or project", text: $query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit {
                    if let highlighted { onPick(highlighted) }
                }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        }
        // Arrow keys move the highlight without leaving the field, so the user
        // never has to tab out of it to choose.
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
    }

    private var optionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    Button {
                        onPick(option)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol(for: option))
                                .foregroundStyle(tint(for: option))
                                .frame(width: 20)

                            Text(label(for: option))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if option == currentDestination {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option == highlighted
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 260)
    }

    // MARK: Options

    /// Everything the to-do could be moved to, filtered by the query.
    ///
    /// A project cannot be moved into itself or into one of its own subtasks,
    /// which would orphan the branch.
    private var options: [Destination] {
        var results: [Destination] = []

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = { name in
            trimmed.isEmpty || name.localizedCaseInsensitiveContains(trimmed)
        }

        if matches("None") || matches("Inbox") {
            results.append(.none)
        }

        results += spaces
            .sorted { $0.sortIndex < $1.sortIndex }
            .filter { matches($0.name) }
            .map { .space($0.uuid) }

        results += todos
            .filter { $0.isProject && $0.uuid != todo.uuid && !isDescendant($0, of: todo) }
            .filter { matches($0.title) }
            .sorted { $0.title < $1.title }
            .map { .project($0.uuid) }

        return results
    }

    /// Whether `candidate` sits somewhere below `ancestor` in the subtask tree.
    private func isDescendant(_ candidate: Todo, of ancestor: Todo) -> Bool {
        var parent = candidate.parent
        while let current = parent {
            if current.uuid == ancestor.uuid { return true }
            parent = current.parent
        }
        return false
    }

    /// Where the to-do lives now, so the picker can mark it.
    private var currentDestination: Destination? {
        if let parent = todo.parent { return .project(parent.uuid) }
        if let space = todo.space { return .space(space.uuid) }
        return Destination.none
    }

    private func moveHighlight(_ delta: Int) {
        let available = options
        guard !available.isEmpty else { return }

        guard let current = highlighted, let index = available.firstIndex(of: current) else {
            highlighted = available.first
            return
        }

        let next = index + delta
        guard available.indices.contains(next) else { return }
        highlighted = available[next]
    }

    // MARK: Presentation

    private func label(for option: Destination) -> String {
        switch option {
        case .none: "None (Inbox)"
        case .space(let id): spaces.first { $0.uuid == id }?.name ?? "Space"
        case .project(let id): todos.first { $0.uuid == id }?.title ?? "Project"
        }
    }

    private func symbol(for option: Destination) -> String {
        switch option {
        case .none: "tray"
        case .space(let id): spaces.first { $0.uuid == id }?.symbolName ?? "square.stack"
        case .project: "list.bullet"
        }
    }

    private func tint(for option: Destination) -> Color {
        switch option {
        case .none: .secondary
        case .space(let id):
            spaces.first { $0.uuid == id }.map { Color(hex: $0.colorHex) } ?? .secondary
        case .project(let id):
            todos.first { $0.uuid == id }?.color ?? .secondary
        }
    }
}
