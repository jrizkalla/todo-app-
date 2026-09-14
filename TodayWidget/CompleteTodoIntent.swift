import AppIntents
import SwiftData
import WidgetKit

/// Marks a to-do complete from the widget, without launching the app.
///
/// Writes through `Todo.setState` rather than assigning `state` directly, so a
/// tick from the home screen runs the same bookkeeping — resolution timestamp,
/// subtask cascade, refiling — that ticking the box inside the app does.
struct CompleteTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete To-Do"
    /// The app must stay closed: the point of the button is to tick something
    /// off without leaving the home screen.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "To-Do")
    var todoID: String

    init() {}

    init(todoID: String) {
        self.todoID = todoID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: todoID),
              let container = try? ModelContainer.widgetContainer()
        else {
            return .result()
        }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.uuid == uuid })

        if let todo = try? context.fetch(descriptor).first {
            _ = todo.setState(.completed)
            try? context.save()
        }

        // Every surface that reads today's list just went stale, not only the
        // one holding the box that was ticked: the progress ring's fraction
        // moved, and the item may have been the one the lock screen was naming.
        // Reloading all of them is what stops two widgets on one screen
        // disagreeing about the same day.
        WidgetCenter.shared.reloadAllTimelines()

        return .result()
    }
}
