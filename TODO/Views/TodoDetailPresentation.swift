import SwiftUI
import SwiftData

/// How the to-do editor is presented, which differs by platform.
///
/// On iOS the editor is a pushed page — a phone has one screen, so the detail
/// *is* the screen. On macOS the stock Calendar app's model is the right one:
/// clicking an event opens a popover anchored to it, and the popover can be
/// dragged out into a real window when the user wants to keep it around. This
/// file holds the macOS half of that, plus the shared plumbing so callers do
/// not each reinvent it.
#if os(macOS)

/// Identifies a to-do in a torn-off detail window.
///
/// A `UUID` rather than the model: `WindowGroup(for:)` encodes its value into
/// the window's restoration state, so it has to be `Codable` and stable across
/// launches, which a `PersistentIdentifier` is not.
struct TodoWindowID: Hashable, Codable {
    let uuid: UUID
}

/// The scene backing torn-off detail windows.
///
/// Registered once in the app body; `openWindow(value:)` with a `TodoWindowID`
/// is what tears a popover off into one of these.
struct TodoDetailWindowScene: Scene {
    let container: ModelContainer
    let settings: AppSettings

    var body: some Scene {
        WindowGroup(id: TodoDetailWindow.id, for: TodoWindowID.self) { $windowID in
            TodoDetailWindowContent(windowID: windowID)
                .environment(settings)
                .modelContainer(container)
        }
        // Sized to the popover, so tearing one off does not change its shape.
        .defaultSize(width: 380, height: 520)
        .windowResizability(.contentMinSize)
    }
}

enum TodoDetailWindow {
    static let id = "todo-detail"
}

/// Resolves the window's to-do from its stable id.
///
/// The lookup happens here rather than at the call site because a restored
/// window comes back with only the id — the to-do it names may since have been
/// deleted, which this handles by saying so instead of failing to open.
private struct TodoDetailWindowContent: View {
    let windowID: TodoWindowID?

    @Environment(\.modelContext) private var context
    @State private var todo: Todo?

    var body: some View {
        Group {
            if let todo {
                TodoDetailCompactView(todo: todo)
            } else {
                ContentUnavailableView(
                    "To-Do Unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("It may have been deleted.")
                )
            }
        }
        .task(id: windowID) { todo = resolve() }
    }

    private func resolve() -> Todo? {
        guard let uuid = windowID?.uuid else { return nil }
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.uuid == uuid })
        return (try? context.fetch(descriptor))?.first
    }
}

#endif

// MARK: - Attaching the editor to a row

extension View {
    /// Present the to-do editor the way this platform expects.
    ///
    /// macOS gets a popover anchored to the list, with a button that tears it
    /// off into a real window. iOS keeps the pushed page it already had, which
    /// is why `RootView`'s `navigationDestination` is untouched on that
    /// platform.
    ///
    /// Attached to an individual *row* rather than to the pane, so the popover
    /// points at the to-do it is editing the way Calendar's does. `todo` is the
    /// row's own item and `selection` the list's shared binding; the popover
    /// presents only on the row where the two match, which is what keeps one
    /// popover on screen instead of one per row.
    @ViewBuilder
    func todoDetailPopover(for todo: Todo, selection: Binding<Todo?>) -> some View {
        #if os(macOS)
        modifier(TodoDetailPopoverModifier(todo: todo, selection: selection))
        #else
        self
        #endif
    }
}

#if os(macOS)

/// Anchors the editor popover to one row and owns the tear-off action.
private struct TodoDetailPopoverModifier: ViewModifier {
    let todo: Todo
    @Binding var selection: Todo?

    @Environment(\.openWindow) private var openWindow

    /// True only on the row the selection names.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { selection?.uuid == todo.uuid },
            set: { shown in if !shown && selection?.uuid == todo.uuid { selection = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            // Anchored to a zero-width strip at the row's leading edge rather
            // than to the row itself. A row spans the full width of the pane,
            // and a popover anchored to something that wide has no room on its
            // trailing side — AppKit flips it to the opposite edge, landing it
            // over the sidebar instead of beside the to-do it belongs to.
            // Anchoring to the left edge leaves the whole pane as trailing
            // space, so the popover opens where the row is.
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 1)
                    .popover(isPresented: isPresented, arrowEdge: .trailing) {
                        TodoDetailCompactView(
                            todo: todo,
                            onTearOff: {
                                // Capture before clearing: dismissing the
                                // popover tears down this presenting view.
                                let id = TodoWindowID(uuid: todo.uuid)
                                selection = nil
                                openWindow(id: TodoDetailWindow.id, value: id)
                            },
                            onClose: { selection = nil }
                        )
                    }
            }
    }
}

#endif

extension View {
    /// The editor for a to-do picked on a calendar that is *itself* a pushed
    /// page.
    ///
    /// A sheet rather than another push, because of what a second
    /// `navigationDestination(item:)` for `Todo` does to the stack it is
    /// declared in. The list registers one at its root, the pushed calendar
    /// would register a second, and SwiftUI resolves the pair by presenting
    /// from the root — so opening a block *replaced* the calendar instead of
    /// covering it, and Back returned to the list the calendar was opened from
    /// rather than to the calendar itself.
    ///
    /// macOS is untouched: there the calendar anchors a popover to the block —
    /// see `todoDetailPopover(for:selection:)` — which involves no navigation
    /// and so never had the collision.
    @ViewBuilder
    func todoDetailSheet(selection: Binding<Todo?>) -> some View {
        #if os(macOS)
        self
        #else
        self.sheet(item: selection) { todo in
            NavigationStack {
                TodoDetailView(todo: todo)
                    // A sheet has no back chevron, so the way out has to be
                    // put here. Clearing the binding rather than calling
                    // `dismiss` because the binding is what presents it, and a
                    // sheet dismissed without clearing it cannot be reopened
                    // on the same to-do.
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selection.wrappedValue = nil }
                        }
                    }
            }
        }
        #endif
    }
}
