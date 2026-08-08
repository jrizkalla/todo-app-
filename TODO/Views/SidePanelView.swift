import SwiftUI
import SwiftData

/// Right-hand panel on wide layouts showing the Inbox and overdue work.
///
/// The spec asks for this on macOS and iPadOS only; `RootView` gates it on the
/// horizontal size class so it never appears on a phone.
struct SidePanelView: View {
    @Binding var selectedTodo: Todo?

    @Environment(\.modelContext) private var context
    @Query private var todos: [Todo]

    /// The panel is a read-mostly surface; rows here are never edited in place,
    /// but `TodoRow` requires a focus binding.
    @FocusState private var unusedFocus: Bool

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        List {
            let overdue = TodoQueries.overdue(todos)
            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { todo in
                        row(todo)
                    }
                } header: {
                    Label("Overdue", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.overdue)
                }
            }

            Section {
                let inbox = TodoQueries.inbox(todos)
                if inbox.isEmpty {
                    Text("Inbox is empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inbox) { todo in
                        row(todo)
                    }
                }
            } header: {
                Label("Inbox", systemImage: "tray")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240, idealWidth: Theme.Metrics.sidePanelWidth)
    }

    private func row(_ todo: Todo) -> some View {
        TodoRow(
            todo: todo,
            showsSpace: true,
            isSelected: selectedTodo?.uuid == todo.uuid,
            onToggle: {
                // Cascade silently here: the panel is a glanceable surface and
                // a modal prompt would be disruptive. The full prompt still
                // appears in the main list.
                if case .needsSubtaskConfirmation = store.setState(todo, to: todo.toggledState) {
                    store.setStateCascading(todo, to: todo.toggledState)
                }
            },
            onSelectState: { newState in
                if case .needsSubtaskConfirmation = store.setState(todo, to: newState) {
                    store.setStateCascading(todo, to: newState)
                }
            },
            titleFieldFocused: $unusedFocus
        )
        .onTapGesture { selectedTodo = todo }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}
