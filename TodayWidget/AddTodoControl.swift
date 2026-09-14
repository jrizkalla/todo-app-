import AppIntents
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

/// Opens the app at the new-to-do composer.
///
/// `openAppWhenRun` is the whole mechanism: the system foregrounds the app and
/// then runs `perform`, which asks for the URL to be opened. The app answers it
/// in `RootView` the same way it answers Cmd+N — see `AppURL`.
struct OpenNewTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add To-Do"
    static var description = IntentDescription("Opens TODO ready to type a new to-do.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppURL.newTodo))
    }
}
