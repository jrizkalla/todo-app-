import SwiftUI
import SwiftData

/// Right-hand panel on wide layouts showing the Inbox and overdue work.
///
/// The spec asks for this on macOS and iPadOS only; `RootView` gates it on the
/// horizontal size class so it never appears on a phone. It sits beside the
/// whole tab view rather than inside any one tab, so the Inbox stays reachable
/// from Today, Lists, and Calendar alike.
struct SidePanelView: View {
    @Binding var selectedTodo: Todo?

    /// Collapses the panel. Supplied by whoever owns the visibility state —
    /// the panel draws the control but does not decide what hiding means.
    var onHide: (() -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var todos: [Todo]

    /// Titles are editable here too, so the panel owns its own focus.
    @FocusState private var focusedTodoID: UUID?

    private var store: TodoStore { TodoStore(context: context) }

    var body: some View {
        // The hide control rides in the Inbox section's own header rather than
        // in a bar of its own. A separate header row sat outside the window's
        // title bar on macOS and read as a tall empty white band above the
        // list, which is exactly the thing it was supposed to be labelling.
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
                let inbox = TodoQueries.inbox(todos, includeResolved: settings.showResolved)
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
                HStack {
                    Label("Inbox", systemImage: "tray")

                    if let onHide {
                        Spacer()
                        Button(action: onHide) {
                            Image(systemName: "sidebar.right")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hide Inbox Panel")
                        .help("Hide the Inbox panel")
                    }
                }
            }
        }
        // `.plain` over `.sidebar`: the sidebar style paints the gray material
        // backdrop AppKit gives source lists, which fought with the content
        // beside it. Plain inherits the window's own background instead.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
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
            onTitleChange: { _ in store.save() },
            focusedTodoID: $focusedTodoID,
            menu: {
                AnyView(
                    Button {
                        focusedTodoID = nil
                        selectedTodo = todo
                    } label: {
                        Label("Show Details", systemImage: "info.circle")
                    }
                )
            }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // The panel selects to-dos too, so its rows anchor the editor popover
        // the same way the main list's do.
        .todoDetailPopover(for: todo, selection: $selectedTodo)
    }
}

#if DEBUG
private struct SidePanelPreviewHost: View {
    @State private var selected: Todo?

    var body: some View {
        SidePanelView(selectedTodo: $selected)
    }
}

#Preview("Side panel") {
    // Overdue work on top, then the Inbox.
    SidePanelPreviewHost()
        .previewEnvironment()
}
#endif
