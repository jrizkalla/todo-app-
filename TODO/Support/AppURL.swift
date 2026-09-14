import Foundation

/// The URLs that reach into the app from outside it.
///
/// One type compiled into both the app and the widget extension, because the
/// two ends of a URL have to agree exactly and a literal written twice is a
/// literal that eventually differs by a character. The extension builds these;
/// `RootView` matches on them.
///
/// A custom scheme rather than a universal link: these are the app talking to
/// itself from its own Control Center button, never anything a web page should
/// be able to aim, and there is no site to host the association file on.
enum AppURL {
    static let scheme = "todoapp"

    /// Open the app ready to type a new to-do.
    ///
    /// What the Control Center button opens. The host names the intent rather
    /// than the destination — *capture something*, not "go to the Inbox" — so
    /// the app stays free to decide where a to-do captured from outside any
    /// list belongs, the same judgement `RootView.captureIntoInbox` already
    /// makes for Cmd+N.
    static let newTodo = URL(string: "\(scheme)://new")!

    /// What an incoming URL is asking for, or `nil` if it is not ours.
    ///
    /// Parsed into a case rather than compared against `newTodo` directly so an
    /// unknown host fails as "not an action I know" instead of silently doing
    /// nothing, and so adding a second action later does not mean adding a
    /// second equality check at the call site.
    static func action(for url: URL) -> Action? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case "new": return .newTodo
        default: return nil
        }
    }

    enum Action: Hashable {
        case newTodo
    }
}
