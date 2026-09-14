import SwiftUI
import WidgetKit

@main
struct TodayWidgetBundle: WidgetBundle {
    var body: some Widget {
        // The home screen list, and the same day measured rather than listed.
        TodayWidget()
        ProgressWidget()
        // The lock screen's one-line slot, above the clock.
        InlineNextWidget()
        // Control Center, the Lock Screen corners, and the Action button — all
        // three come from one `ControlWidget`.
        AddTodoControl()
    }
}
