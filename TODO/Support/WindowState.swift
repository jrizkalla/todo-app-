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

/// Whether the caret is in a text field.
///
/// Only Select All asks, and it exists because a menu item's `keyboardShortcut`
/// outranks a focused `TextField`: with Cmd+A in the menu, typing a title and
/// pressing it selected every *row* instead of the text the user was looking
/// at. Declining the command once it arrives does not help — the menu has
/// already taken the keystroke by then — so the item asks this first and
/// forwards the key to the field when the answer is yes.
///
/// Asked of AppKit rather than published by the views, which is what makes it
/// right for *every* field rather than the list's two. SwiftUI's own channels
/// could not carry it: a `focusedSceneValue` propagates only while the view
/// publishing it is the focused subtree, and the moment this has to be true —
/// a text field holding the keyboard — is exactly the moment the list around it
/// is not. The window's first responder is the same fact without the
/// indirection, and the detail editor, the space editor and the settings sheet
/// get the behaviour without each having to remember to report in.
@MainActor
enum TextEditingPresence {
    /// True when the focused window's first responder takes text input.
    ///
    /// Asked as "does this responder accept typing" rather than "is it an
    /// `NSTextView`", because a SwiftUI `TextField` on macOS is not one: it is
    /// drawn by a hosting view, and which class ends up first responder while it
    /// has the caret is a SwiftUI implementation detail that has changed between
    /// releases. `NSTextInputClient` is the protocol anything editable must
    /// conform to in order to receive keystrokes at all, so it identifies a
    /// field the user is typing in without depending on how it was built — a row
    /// title, the search box, the detail editor's notes, all the same.
    ///
    /// `mainWindow` backs up `keyWindow` because the latter is nil whenever the
    /// app is not active — which is every time the menu is driven from outside
    /// it, scripting and accessibility included — and answering "no field has
    /// the caret" there would send Cmd+A to the rows behind a title the user was
    /// editing.
    static var isEditing: Bool {
        #if os(macOS)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return window?.firstResponder is NSTextInputClient
        #else
        return false
        #endif
    }
}
