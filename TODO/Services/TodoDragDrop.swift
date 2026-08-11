import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A to-do being dragged between surfaces.
///
/// Carries the `uuid` rather than the model object: a `Todo` is a SwiftData
/// object bound to a context and cannot cross a drag session, whereas the uuid
/// is stable and the receiver already has the store to look it up in.
///
/// Registered under its own content type rather than as plain text so a drag
/// from the Inbox is not accepted by every text field in the app, and so a
/// stray string dragged in from outside is not mistaken for a to-do.
struct TodoTransfer: Codable, Transferable {
    let uuid: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .todoItem)
    }
}

extension UTType {
    /// Declared in the app's Info.plist as an exported type.
    static let todoItem = UTType(exportedAs: "com.johnrizkalla.app.TODO.todo-item")
}

/// What dropping a to-do somewhere should do to it.
///
/// Written as one function so every drop target agrees on the meaning of a
/// destination. The rules follow what each list *is*, so that a to-do dropped
/// somewhere afterwards actually appears there — dropping onto Today without
/// setting a date would file it and then leave it invisible in the list the
/// user just dropped it on, which reads as the drop having failed.
enum TodoDropAction {
    /// File `todo` as though it belonged to `destination`.
    ///
    /// - Returns: `false` when the destination cannot accept a drop, so the
    ///   caller can refuse it rather than silently doing nothing.
    @discardableResult
    static func apply(
        _ destination: ListDestination,
        to todo: Todo,
        store: TodoStore,
        allTodos: [Todo],
        spaces: [Space],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Bool {
        switch destination {
        case .inbox:
            // The Inbox is "unfiled": no home and no date is what puts a to-do
            // there, so dropping onto it has to clear both.
            store.update(todo) {
                $0.assignedDate = nil
                $0.assignedHasTime = false
            }
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: nil)
            return true

        case .today:
            store.update(todo) {
                $0.assignedDate = calendar.startOfDay(for: now)
                $0.assignedHasTime = false
            }
            return true

        case .thisWeek:
            // Today is inside this week and needs no guessing, which is the
            // same choice the create button makes for this list.
            store.update(todo) {
                $0.assignedDate = calendar.startOfDay(for: now)
                $0.assignedHasTime = false
            }
            return true

        case .anytime:
            // Anytime means scheduled-but-undated. Clearing the date is enough;
            // the filing rules put it here once it has a home, and in the Inbox
            // when it does not.
            store.update(todo) {
                $0.assignedDate = nil
                $0.assignedHasTime = false
            }
            return true

        case .space(let id):
            guard let space = spaces.first(where: { $0.uuid == id }) else { return false }
            // Leaves any parent behind: a to-do belongs to one container, and
            // keeping the old parent would file it into a project that may sit
            // in a different space entirely.
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: space)
            return true

        case .project(let id):
            guard let project = allTodos.first(where: { $0.uuid == id }),
                  project.uuid != todo.uuid
            else { return false }
            return store.adopt(todo, asSubtaskOf: project)

        case .logbook:
            // The Logbook is a record of finished work, not a place to file
            // something. Completing a to-do by dropping it here would be a
            // destructive act triggered by a slip of the mouse.
            return false
        }
    }

    /// Whether a destination will accept a drop at all.
    ///
    /// Used to refuse the drag up front, so the cursor does not promise a drop
    /// that will be thrown away.
    static func accepts(_ destination: ListDestination, todo: Todo) -> Bool {
        switch destination {
        case .logbook:
            false
        case .project(let id):
            // A project cannot be dropped into itself.
            id != todo.uuid
        default:
            true
        }
    }
}

extension View {
    /// Accept to-dos dropped onto a list destination.
    ///
    /// Wrapped as a modifier because four different surfaces need identical
    /// behaviour — the sidebar rows, the side panel, the list pane, and the
    /// calendar's all-day row — and the highlight-while-targeted half is easy
    /// to leave out when each writes its own.
    func todoDropTarget(
        _ destination: ListDestination,
        store: TodoStore,
        allTodos: [Todo],
        spaces: [Space],
        isTargeted: Binding<Bool>? = nil
    ) -> some View {
        modifier(
            TodoDropTargetModifier(
                destination: destination,
                store: store,
                allTodos: allTodos,
                spaces: spaces,
                externalTargeting: isTargeted
            )
        )
    }

    /// Make a to-do draggable to another list or onto the calendar.
    ///
    /// `isEnabled` must never add or remove `draggable` itself — see
    /// `TodoDraggableModifier` for why, and for what suppresses the drag
    /// instead.
    func todoDraggable(_ todo: Todo, isEnabled: Bool = true) -> some View {
        modifier(TodoDraggableModifier(todo: todo, isEnabled: isEnabled))
    }
}

/// Attaches the drag source with a view type that does not change when the row
/// gains or loses focus.
///
/// `draggable` is attached unconditionally. This previously hung the app: a
/// `@ViewBuilder` `if isEnabled` produced two structurally different view
/// types, so every flip of the flag changed this subtree's identity and made
/// SwiftUI tear the whole thing down — including the row's `TextField`. That
/// field is what holds focus, so destroying it cleared `focusedTodoID`, which
/// flipped `isEnabled` back, which rebuilt the field, which took focus again.
/// The row oscillated inside a single layout pass: the main thread never
/// returned, and each turn allocated a fresh subtree, so memory climbed until
/// the OS killed the app. It reproduced on the second tap of a row — the tap
/// that first moves focus into the title.
///
/// The gesture is suppressed instead, which keeps one stable view type across
/// the flip. That still serves the original reason for the branch: a drag
/// gesture that exists but declines to start would swallow the press it was
/// offered, and a focused title has to keep its press for caret placement and
/// text selection.
private struct TodoDraggableModifier: ViewModifier {
    let todo: Todo
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.draggable(TodoTransfer(uuid: todo.uuid)) {
            // The preview under the cursor: enough to tell which to-do is in
            // flight when several are being moved in turn.
            Label(
                todo.title.isEmpty ? "Untitled" : todo.title,
                systemImage: todo.isProject ? "list.bullet" : "circle"
            )
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
        }
        // Suppresses the drag while the row is being edited, without removing
        // the modifier. A zero-distance drag gesture claims the press ahead of
        // the drag session but does nothing with it, so a press inside the
        // focused title goes to the text field for caret placement and
        // selection — the behaviour the old `if` branch was protecting.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0),
            including: isEnabled ? [] : .gesture
        )
    }
}

private struct TodoDropTargetModifier: ViewModifier {
    let destination: ListDestination
    let store: TodoStore
    let allTodos: [Todo]
    let spaces: [Space]
    let externalTargeting: Binding<Bool>?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                // Drawn behind rather than as an overlay so it never sits over
                // the row's own text or intercepts the drop itself.
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.18 : 0))
                    .animation(Theme.Animation.quick, value: isTargeted)
            }
            .dropDestination(for: TodoTransfer.self) { items, _ in
                var handled = false
                for item in items {
                    guard let todo = allTodos.first(where: { $0.uuid == item.uuid }) else { continue }
                    if TodoDropAction.apply(
                        destination,
                        to: todo,
                        store: store,
                        allTodos: allTodos,
                        spaces: spaces
                    ) {
                        handled = true
                    }
                }
                return handled
            } isTargeted: { targeted in
                isTargeted = targeted
                externalTargeting?.wrappedValue = targeted
            }
    }
}
