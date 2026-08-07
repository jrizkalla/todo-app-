import SwiftUI

/// macOS menu bar commands.
struct AppCommands: Commands {
    var body: some Commands {
        // Replaces the default "New Item"; the list view owns the shortcut, so
        // this entry documents it in the menu.
        CommandGroup(replacing: .newItem) {
            Button("New To-Do") {
                NotificationCenter.default.post(name: .newTodoRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Calendar View") {
                NotificationCenter.default.post(name: .toggleCalendarRequested, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let newTodoRequested = Notification.Name("newTodoRequested")
    static let toggleCalendarRequested = Notification.Name("toggleCalendarRequested")
}
