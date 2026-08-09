import SwiftUI

/// The checkbox in a todo row.
///
/// A tap toggles open/completed.
struct TodoCheckbox: View {
    let state: CompletionState
    let tint: Color
    let onToggle: () -> Void
    let onSelect: (CompletionState) -> Void

    @State private var isPressed = false

    var body: some View {
        // Not a `Button`: inside a `List` row the button's own long press is
        // forwarded to the row's context menu, so the status picker never
        // opens. Driving both gestures explicitly keeps them here.
        checkbox
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Status")
            .accessibilityValue(state.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .onTapGesture { onToggle() }
    }

    private var checkbox: some View {
        Group {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1.5)
                    .frame(width: Theme.Metrics.checkboxSize, height: Theme.Metrics.checkboxSize)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fillColor)
                    .frame(width: Theme.Metrics.checkboxSize, height: Theme.Metrics.checkboxSize)
                    .opacity(state.isResolved ? 1 : 0)
                    .scaleEffect(state.isResolved ? 1 : 0.5)

                // Half-fill marks "started" without claiming completion.
                if state == .started {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.Palette.started)
                        .frame(width: 9, height: 9)
                        .transition(.scale.combined(with: .opacity))
                }

                if state == .completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }

                if state == .cancelled {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isPressed ? 0.86 : 1)
            .animation(Theme.Animation.toggle, value: state)
            .animation(Theme.Animation.toggle, value: isPressed)
        }
    }

    /// An open box carries its space or project color too, which is what makes
    /// a mixed list scannable by color at a glance. Without a color set, `tint`
    /// is the app accent, so uncolored items stay neutral.
    private var strokeColor: Color {
        switch state {
        case .open: tint.opacity(0.75)
        case .started: Theme.Palette.started
        case .completed: tint
        case .cancelled: Theme.Palette.cancelled
        }
    }

    private var fillColor: Color {
        switch state {
        case .completed: tint
        case .cancelled: Theme.Palette.cancelled
        default: .clear
        }
    }
}



#if DEBUG
#Preview("Checkbox states") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(CompletionState.allCases, id: \.self) { state in
            HStack {
                TodoCheckbox(state: state, tint: .blue, onToggle: {}, onSelect: { _ in })
                Text(state.label)
            }
        }
    }
    .padding()
}

#endif
