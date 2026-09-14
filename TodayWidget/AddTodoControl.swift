import AppIntents
import SwiftData
import SwiftUI
import WidgetKit

/// A Control Center button that opens the app ready to type a new to-do.
///
/// A control rather than another home screen widget because capture is the one
/// thing worth reaching from *anywhere* — the Control Center pulls down over
/// whatever app is open, which is exactly the moment a to-do occurs to someone.
/// It is also assignable to the Lock Screen's corner buttons and the Action
/// button, which the system offers for free once a control exists.
///
/// The button opens the app rather than capturing silently in the background.
/// A to-do created without a title is one the user has no way to name, and a
/// control that flashes and leaves nothing on screen gives no sign it worked —
/// so this one is honest about being a shortcut to the composer.
struct AddTodoControl: ControlWidget {
    static let kind = "AddTodoControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNewTodoIntent()) {
                // A custom *symbol*, not a drawn view: Control Center renders a
                // control's icon by flattening it into a single-colour template
                // mask, which an arbitrary SwiftUI view does not survive — a
                // stroked box with a badge over it arrived as a bare checkmark,
                // and a `Canvas` arrived as nothing at all. A symbol set is what
                // that pipeline is built to consume, so it renders correctly in
                // Control Center, on the Lock Screen and on the Action button
                // alike. See `WidgetAssets.xcassets/checkbox.plus.symbolset`.
                // Through the generated `ImageResource` rather than the bare
                // name: a string is resolved against the *main app's* bundle,
                // which does not hold this catalog — the extension's does — so
                // the lookup missed and the system fell back to the app icon's
                // glyph. The resource carries its own bundle.
                Label("Add To-Do", image: .checkboxPlus)
            }
        }
        .displayName("Add To-Do")
        .description("Capture a new to-do.")
    }
}

/// Creates the to-do, then opens the app on it.
///
/// The row is written here, in the extension, rather than by asking the app to
/// create one once it is open. The first attempt did the latter — `perform`
/// returned an `OpenURLIntent` for the app's own scheme — and the button did
/// nothing at all: returning a URL to open is not a thing a control's intent is
/// allowed to do, and it fails silently rather than reporting anything. Writing
/// the row here needs no such permission; the extension already has the store
/// open read-write, which is how the widget's checkbox completes a to-do.
///
/// `openAppWhenRun` then foregrounds the app, which is the half that still has
/// to happen out here: an empty row the user cannot see is one they have no way
/// to name, so the button has to land them on it. The app finds it through
/// `AppSettings.pendingCapture` — see `RootView`.
struct OpenNewTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add To-Do"
    static var description = IntentDescription("Adds a to-do to your Inbox and opens it.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let container = try? ModelContainer.widgetContainer() else {
            // The store could not be opened — the app has not been launched
            // yet, or the App Group is missing from the build. Still open the
            // app: launching it is exactly what fixes the first case.
            return .result()
        }

        let context = container.mainContext

        // `TodoStore.createTodo` is the app's own path for this, but it is not
        // reachable here: it pulls in the undo stack and the recurrence engine,
        // which is a large dependency chain to load into an extension with a
        // hard memory budget for the sake of one insert. What that method does
        // for an *unfiled* capture — no space, no parent, no date — is these
        // three steps, so they are spelled out rather than borrowed.
        let todo = Todo()
        todo.sortIndex = Self.nextInboxSortIndex(in: context)
        context.insert(todo)
        // Files it to the Inbox, since it carries no date and no home. Called
        // rather than assigning `bucket` directly, so the rule stays the
        // model's to state.
        todo.refileForCurrentScheduling()
        try? context.save()

        // Handed over by id rather than by object: the app opens its own
        // container, so the row has to be found again on the other side.
        PendingCapture.set(todo.uuid)

        return .result()
    }

    /// Where a new unfiled row sorts, matching `TodoStore.nextSortIndex`.
    ///
    /// Asked of SQLite with a fetch limit rather than by measuring the whole
    /// Inbox: an extension cannot afford to fault in every top-level to-do to
    /// read the largest index among them.
    @MainActor
    private static func nextInboxSortIndex(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.space == nil && $0.parent == nil }
        )
        descriptor.sortBy = [SortDescriptor(\Todo.sortIndex, order: .reverse)]
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first?.sortIndex ?? -1) + 1
    }
}
