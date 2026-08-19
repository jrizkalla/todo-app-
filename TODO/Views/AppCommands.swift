import SwiftUI
import SwiftData

/// macOS menu bar commands.
///
/// Every shortcut in the app is declared here rather than on the views that
/// answer them. Two reasons: a `keyboardShortcut` attached to a view only fires
/// while that view is on screen and able to take focus, which is not true of a
/// list the user has not clicked into yet; and a shortcut with no menu item is
/// a shortcut nobody discovers. The menu owns the key, posts a notification,
/// and whichever surface currently holds the selection acts on it.
struct AppCommands: Commands {
    /// The app's container, handed down rather than taken from the
    /// environment: a `Commands` tree is not inside the scene's view hierarchy,
    /// so `@Environment(\.modelContext)` there resolves to a default container
    /// rather than this app's — undo would then quietly act on an empty store.
    let container: ModelContainer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Deliberately *not* `.create`, which is the + button's request and
            // means "new thing here" — a block on the calendar, a row in
            // whichever list is open. Cmd+N is the capture shortcut: it is
            // pressed to get something out of the user's head before they have
            // decided where it belongs, and the Inbox is where the app says
            // undecided work lives. Routing it through the open screen instead
            // put a to-do into whatever list happened to be showing.
            Button("New To-Do") {
                NotificationCenter.default.post(name: .createInInboxRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("To-Do") {
            command(.showDetail, key: .return)
            command(.toggleDone, key: "k")

            Divider()

            command(.schedule, key: "s")
            command(.move, key: "m")
            command(.duplicate, key: "d")

            Divider()

            // Delete rather than Backspace: they are the same physical key on
            // an Apple keyboard, and `.delete` is what SwiftUI calls it.
            command(.delete, key: .delete)
        }

        // Replaces the system Undo/Redo items, which drive `UndoManager` and
        // would otherwise sit in the menu permanently disabled — this app's
        // history is `UndoStack`, not the responder chain's.
        CommandGroup(replacing: .undoRedo) {
            UndoMenuItems(context: container.mainContext)
        }

        CommandGroup(after: .textEditing) {
            command(.search, key: "f")
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Calendar View") {
                NotificationCenter.default.post(name: .toggleCalendarRequested, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }

    private func command(_ command: KeyboardCommand, key: KeyEquivalent) -> some View {
        Button(command.title) {
            NotificationCenter.default.post(name: command.notificationName, object: nil)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}

/// The Edit menu's Undo and Redo.
///
/// A view rather than two `Button`s inline, so it can observe `UndoStack` and
/// name what the shortcut would actually undo — "Undo Complete" rather than a
/// bare "Undo". Commands are not part of the view hierarchy, so the stack is
/// reached through its shared instance rather than the environment.
private struct UndoMenuItems: View {
    let context: ModelContext

    @State private var undoStack = UndoStack.shared

    var body: some View {
        Button(undoStack.undoActionName.map { "Undo \($0)" } ?? "Undo") {
            undoStack.undo(in: context)
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!undoStack.canUndo)

        Button(undoStack.redoActionName.map { "Redo \($0)" } ?? "Redo") {
            undoStack.redo(in: context)
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!undoStack.canRedo)
    }
}

extension Notification.Name {
    static let toggleCalendarRequested = Notification.Name("toggleCalendarRequested")
    /// Cmd+N: capture something into the Inbox, wherever the user is.
    ///
    /// Answered by `RootView` rather than by a list, because the point of the
    /// shortcut is that it does *not* depend on which screen is open.
    static let createInInboxRequested = Notification.Name("createInInboxRequested")
}

extension View {
    /// Answer the app's keyboard commands while this view holds the selection.
    ///
    /// `isActive` is what keeps one keystroke from firing in several places at
    /// once: every tab's view stays alive after its first visit, so the list in
    /// a background tab is still listening. Only the surface that currently has
    /// something selected should act.
    func keyboardCommands(
        isActive: Bool,
        perform: @escaping (KeyboardCommand) -> Void
    ) -> some View {
        modifier(KeyboardCommandsModifier(isActive: isActive, perform: perform))
    }
}

private struct KeyboardCommandsModifier: ViewModifier {
    let isActive: Bool
    let perform: (KeyboardCommand) -> Void

    func body(content: Content) -> some View {
        // One receiver per command. `onReceive` is the right tool despite the
        // repetition: it tears down with the view, so a list that goes away
        // stops listening without any bookkeeping of its own.
        KeyboardCommand.allCases.reduce(AnyView(content)) { view, command in
            AnyView(
                view.onReceive(
                    NotificationCenter.default.publisher(for: command.notificationName)
                ) { _ in
                    guard isActive else { return }
                    perform(command)
                }
            )
        }
    }
}
