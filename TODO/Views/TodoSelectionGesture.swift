import SwiftUI

/// Which of the three things a click on a row meant.
///
/// Split out from the gesture recognizers so the decision can be tested: the
/// recognizers themselves are SwiftUI's and only reachable by an actual click,
/// but *what a modified click means* is this app's rule and is the part worth
/// pinning down. `TodoSelectionGesture` below is then only wiring — each
/// recognizer reports the modifiers it fired for, and this says what to do.
enum RowClickIntent: Equatable {
    /// The list's existing two-stage tap: expand, then open the detail.
    case plain
    /// Add or remove this one row.
    case toggle
    /// Select from the anchor to this row.
    case extend

    /// Resolve a click into an intent.
    ///
    /// - Parameters:
    ///   - modifiers: which modifier keys were down. Always empty on iOS.
    ///   - isSelecting: whether iOS's explicit Select mode is on.
    static func resolve(modifiers: EventModifiers, isSelecting: Bool) -> RowClickIntent {
        // Shift wins over Command when both are down. That is the platform
        // convention — Shift-Cmd-click extends — and it also reads correctly:
        // the more specific gesture is the one the user went further to ask for.
        if modifiers.contains(.shift) { return .extend }
        if modifiers.contains(.command) { return .toggle }
        // With no modifier, a tap toggles only inside iOS's mode. On macOS
        // `isSelecting` is never set, so an unmodified click always falls
        // through to the ordinary tap — the behaviour the app had before
        // multi-select existed.
        return isSelecting ? .toggle : .plain
    }
}

/// The tap that selects a row, in the shape each platform expects.
///
/// On macOS the modifier keys say what the user meant, so a row carries three
/// recognizers: Shift-click extends, Cmd-click toggles, and a plain click does
/// whatever the list normally does — expand the row, or open its detail on a
/// second click. There is no mode to enter and nothing to turn off, which is
/// how every other Mac list behaves.
///
/// On iOS there are no modifiers, so selection is a mode: while it is on, every
/// tap toggles a row, and while it is off taps behave exactly as they did
/// before this existed.
///
/// Written as one modifier so the two platforms' rules sit side by side. They
/// are the same feature and diverge only in how the user says which of the
/// three things they want, and splitting them across two files would let them
/// drift into being two different features.
struct TodoSelectionGesture: ViewModifier {
    /// What a plain, unmodified click does — the list's existing two-stage tap.
    let onPlainTap: () -> Void
    /// Add or remove this one row: Cmd-click, or any tap in iOS's Select mode.
    let onToggle: () -> Void
    /// Select everything from the anchor to this row. macOS only.
    let onExtend: () -> Void
    /// Whether iOS's explicit selection mode is on. Ignored on macOS, where
    /// there is no mode.
    let isSelecting: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            // `simultaneousGesture`, not `gesture`: a plain `.gesture` claims
            // the mouse-down exclusively, and wins that claim before a drag
            // has moved far enough to be recognized — so `.draggable` on the
            // same row (attached in `TodoDraggableModifier`) never saw enough
            // movement to start, and a row could not be lifted at all. Letting
            // both recognizers see the same press lets whichever one the
            // gesture actually matches — a stationary click or a drag past the
            // threshold — win instead of the tap winning by default.
            //
            // Ordered most specific first: a Shift-Cmd-click reaches the shift
            // recognizer, and `RowClickIntent` agrees with that ordering rather
            // than restating it.
            .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { perform(.shift) })
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded { perform(.command) })
            .simultaneousGesture(TapGesture().onEnded { perform([]) })
        #else
        // There are no modifiers on iOS, so the mode is the whole decision.
        content.onTapGesture { perform([]) }
        #endif
    }

    /// Route a click through the shared rule and run whatever it resolved to.
    private func perform(_ modifiers: EventModifiers) {
        switch RowClickIntent.resolve(modifiers: modifiers, isSelecting: isSelecting) {
        case .plain: onPlainTap()
        case .toggle: onToggle()
        case .extend: onExtend()
        }
    }
}

extension View {
    /// Attach the platform's row-selection gesture.
    ///
    /// Replaces the plain `onTapGesture` the list used to put on each row —
    /// the unmodified path through this is exactly that gesture.
    func todoSelectionGesture(
        isSelecting: Bool,
        onPlainTap: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onExtend: @escaping () -> Void
    ) -> some View {
        modifier(
            TodoSelectionGesture(
                onPlainTap: onPlainTap,
                onToggle: onToggle,
                onExtend: onExtend,
                isSelecting: isSelecting
            )
        )
    }
}
