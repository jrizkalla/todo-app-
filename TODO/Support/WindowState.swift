import SwiftUI

/// What one window is showing.
///
/// The value a `WindowGroup` is keyed on, which is what makes windows both
/// independent and addressable. Independent because SwiftUI gives each open
/// window its own binding to one of these, so two windows sit on two different
/// lists without either knowing about the other. Addressable because opening a
/// window *with* a value puts it straight onto that list — which is what "Open
/// in New Window" on a space or project needs, and what lets the system restore
/// the arrangement on the next launch.
///
/// Only the coarse position is stored: which tab, and which list. Selection,
/// scroll offset, and the calendar's anchor day are deliberately left out —
/// they are where the user was looking a moment ago rather than where they
/// were working, and restoring them a day later would be a guess.
struct WindowState: Codable, Hashable, Identifiable {
    /// Distinguishes two windows that happen to be showing the same thing.
    ///
    /// A `WindowGroup` treats its value as the window's identity: opening a
    /// window with a value equal to an existing one's brings that window
    /// forward instead of making a second. Two windows on the same project is
    /// a reasonable thing to want — one per monitor, say — so each carries an
    /// id of its own to keep them distinct. It is also what window-scoped
    /// commands address; see `WindowIdentity`.
    var id: UUID

    var tab: AppTab

    /// The list the Lists tab is showing. Optional to match the split view's
    /// own selection binding, which is empty until something is picked.
    var list: ListDestination?

    init(id: UUID = UUID(), tab: AppTab = .lists, list: ListDestination? = .today) {
        self.id = id
        self.tab = tab
        self.list = list
    }

    /// A window opened onto one list, from "Open in New Window".
    static func showing(_ destination: ListDestination) -> WindowState {
        WindowState(tab: .lists, list: destination)
    }
}

/// Where the Inbox lives in the shell.
///
/// The tab and the sidebar row are alternatives, never both: two entry points
/// to one screen leave the user no way to tell which one they are on. Which one
/// survives turns on whether the app can open a second window — a phone cannot,
/// and there a sidebar row is two navigation steps from anywhere, so the tab
/// earns its place. Everywhere else the Inbox is a list like any other, and can
/// be pulled into a window of its own when it is wanted beside something.
///
/// One type rather than a `!` in each view, so the two halves cannot drift
/// apart into a build with both entry points or neither.
enum InboxPlacement {
    case tab, sidebarRow

    /// - Parameter supportsMultipleWindows: SwiftUI's own answer, which is
    ///   false only where a second scene cannot be opened.
    static func forLayout(supportsMultipleWindows: Bool) -> InboxPlacement {
        supportsMultipleWindows ? .sidebarRow : .tab
    }

    var showsTab: Bool { self == .tab }
    var showsSidebarRow: Bool { self == .sidebarRow }
}

/// Which window a menu command was meant for.
///
/// Menu commands are app-wide, but the work they ask for belongs to one window:
/// Cmd+N should capture a to-do in the window the user is typing in, not in
/// every window at once. `AppCommands` reads the focused window's id and posts
/// it alongside the notification; each `RootView` compares it against its own
/// and ignores what is not addressed to it.
///
/// A notification rather than a `FocusedValue` action closure because the
/// commands already travel this way, and because the shortcut has to work from
/// tabs that hold no list at all — see `RootView.captureIntoInbox`.
enum WindowIdentity {
    /// The key the target window's id travels under.
    static let userInfoKey = "windowID"

    /// Whether `notification` is addressed to the window identified by `id`.
    ///
    /// An unaddressed notification — one posted with no window in mind, as the
    /// widget and the tests do — is answered by every window. That is the old
    /// single-window behaviour, which is the right fallback: better a to-do
    /// created twice than a shortcut that silently does nothing.
    static func isTarget(_ notification: Notification, _ id: UUID) -> Bool {
        guard let target = notification.userInfo?[userInfoKey] as? UUID else { return true }
        return target == id
    }
}

/// The focused window's id, published by each `RootView` for the menu bar.
///
/// `FocusedValue` rather than a shared observable: "which window is frontmost"
/// is exactly what SwiftUI's focus system already tracks, and a static would
/// have to be kept in step with window activation by hand.
struct FocusedWindowID: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var windowID: UUID? {
        get { self[FocusedWindowID.self] }
        set { self[FocusedWindowID.self] = newValue }
    }
}
