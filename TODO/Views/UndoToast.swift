import SwiftUI
import SwiftData

/// The transient "Undo" offer shown after a hard-to-reverse action.
///
/// The counterpart to Cmd+Z: on iOS there is no keyboard to press, so the
/// affordance has to appear on screen. It is deliberately small and short-lived
/// — the action already happened, and the toast is an offer, not a
/// confirmation the user has to dismiss before carrying on.
///
/// Attached once, at the app shell, rather than per list. The action that
/// raised it usually moved a row *out* of the list the user was on, so a toast
/// owned by that list would animate away together with the row it was offering
/// to bring back.
struct UndoToast: View {
    @State private var undoStack = UndoStack.shared
    @Environment(\.modelContext) private var context

    /// How long the offer stands before it fades on its own.
    private static let duration: Duration = .seconds(4)

    var body: some View {
        // Rendered from the stack's toast rather than a local copy, so undoing
        // from the keyboard on a Mac with a Catalyst-style window also clears
        // whatever the toast was offering.
        if let action = undoStack.toast {
            HStack(spacing: 12) {
                Text(action.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Button("Undo") {
                    undoStack.undo(in: context)
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(.regularMaterial)
            }
            .overlay {
                Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            // A swipe down is the other way to say "not interested", matching
            // how the system's own transient banners behave.
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        guard value.translation.height > 0 else { return }
                        withAnimation(Theme.Animation.panel) { undoStack.dismissToast() }
                    }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Keyed to the generation rather than to the action, so a second
            // action replacing the first restarts the clock instead of
            // inheriting what was left of the previous one.
            .task(id: undoStack.toastGeneration) {
                let generation = undoStack.toastGeneration
                try? await Task.sleep(for: Self.duration)
                guard !Task.isCancelled else { return }
                withAnimation(Theme.Animation.panel) {
                    undoStack.dismissToast(ifGeneration: generation)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(action.name). Double tap Undo to reverse it.")
        }
    }
}

extension View {
    /// Float the undo offer above this view, clear of the tab bar.
    func undoToast() -> some View {
        overlay(alignment: .bottom) {
            UndoToast()
                .padding(.bottom, 8)
                // The toast is an offer, not a layer over the app: anywhere it
                // is not drawn stays touchable, so the list underneath keeps
                // taking taps while it is on screen.
                .allowsHitTesting(true)
        }
        .animation(Theme.Animation.panel, value: UndoStack.shared.toastGeneration)
    }
}
