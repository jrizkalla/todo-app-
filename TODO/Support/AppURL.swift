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

/// A to-do created outside the app, waiting for the app to show it.
///
/// The Control Center button writes its row in the extension and then asks the
/// system to foreground the app — two halves in two processes, so the id has to
/// travel between them. It goes through the app group's `UserDefaults`, the
/// same container the store itself lives in, because that is the one place both
/// sides can already reach.
///
/// Deliberately not `AppSettings`: this is a one-shot message rather than a
/// preference. It is *consumed* — read and cleared in one step — so a capture
/// is answered exactly once, and re-opening the app later does not create a
/// second empty row for a button pressed yesterday.
enum PendingCapture {
    static let key = "pendingCaptureTodoID"

    /// The app group's shared defaults, which both processes can reach.
    private static var shared: UserDefaults? {
        UserDefaults(suiteName: AppSchema.appGroupIdentifier)
    }

    /// Record the row the app should open on.
    static func set(_ id: UUID, in defaults: UserDefaults? = shared) {
        defaults?.set(id.uuidString, forKey: key)
    }

    /// Take the waiting row's id, if there is one, and clear it.
    ///
    /// Read-and-clear in one call rather than a getter beside a separate
    /// `clear()`: every caller wants both, and splitting them is how a capture
    /// gets answered twice by two windows.
    ///
    /// A value that will not parse is cleared too. It can never name a row, so
    /// leaving it would mean asking about it on every launch forever.
    static func take(from defaults: UserDefaults? = shared) -> UUID? {
        guard let defaults, let raw = defaults.string(forKey: key) else { return nil }

        defaults.removeObject(forKey: key)
        return UUID(uuidString: raw)
    }
}
