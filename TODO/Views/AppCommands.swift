import SwiftUI

/// macOS menu bar commands.
///
/// Every shortcut in the app is declared here rather than on the views that
/// answer them. Two reasons: a `keyboardShortcut` attached to a view only fires
/// while that view is on screen and able to take focus, which is not true of a
/// list the user has not clicked into yet; and a shortcut with no menu item is
/// a shortcut nobody discovers. The menu owns the key, posts a notification,
/// and whichever surface currently holds the selection acts on it.
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command(.create, key: "n")
        }

        CommandMenu("To-Do") {
            command(.showDetail, key: .return)
            command(.toggleDone, key: "k")

            Divider()

            command(.schedule, key: "s")
            command(.move, key: "m")
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

extension Notification.Name {
    static let toggleCalendarRequested = Notification.Name("toggleCalendarRequested")
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
