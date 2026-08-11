import SwiftUI

/// What the right-hand panel is currently showing.
///
/// The panel is one surface with two jobs. By default it is the Inbox — the
/// unfiled work that has no other home, reachable from every tab. But a scoped
/// calendar splits its own list in half: dated work goes onto the grid, and
/// undated work has nowhere to appear at all. Handing the panel that remainder
/// makes the two surfaces add up to the whole list again, and puts the undated
/// items within dragging distance of the day they belong on.
enum SidePanelScope: Hashable {
    /// The default: unfiled work, plus anything overdue.
    case inbox
    /// The unscheduled remainder of a space or project being viewed as a
    /// calendar. Only ever `.space` or `.project` — the cross-cutting lists
    /// have no calendar of their own to be opened from.
    case list(ListDestination)
}

/// The channel a scoped calendar uses to tell the panel what it is showing.
///
/// A shared observable rather than a `PreferenceKey` because of where the two
/// ends sit: the panel is an overlay on `RootView`, while the scoped calendar
/// is pushed inside the Lists tab's `NavigationSplitView` detail stack. A
/// preference would have to climb out of a `navigationDestination` body to
/// reach an ancestor of the whole `TabView`, which SwiftUI does not promise.
/// This follows what `RemindersImporter` and `CalendarEventStore` already do.
///
/// Scope is *claimed* rather than merely set: every calendar that takes over
/// the panel gets a token back, and only the holder of the current token can
/// release it. Two scoped calendars can be alive at once — the Lists tab keeps
/// its pushed screen mounted while the user visits another tab — and without
/// tokens the one disappearing would clear the scope the one appearing had
/// just set, dropping the panel back to the Inbox underneath a calendar that
/// is still on screen.
@Observable
@MainActor
final class SidePanelScopeModel {
    static let shared = SidePanelScopeModel()

    private(set) var scope: SidePanelScope = .inbox

    /// Identifies one claim, so a stale release cannot revoke a newer one.
    private var token = UUID()

    init() {}

    /// Point the panel at a list. The returned token releases this claim.
    @discardableResult
    func claim(_ destination: ListDestination) -> UUID {
        scope = .list(destination)
        token = UUID()
        return token
    }

    /// Hand the panel back to the Inbox, if `token` is still the current claim.
    func release(_ token: UUID) {
        guard self.token == token else { return }
        scope = .inbox
    }
}
