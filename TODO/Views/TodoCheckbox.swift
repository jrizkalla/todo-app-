import SwiftUI

/// The box itself, with no gestures attached.
///
/// Split out from `TodoCheckbox` so the widget can draw the identical box while
/// supplying its own tap handling: there, the checkbox has to be a `Button`
/// wrapping an `AppIntent` to complete a to-do without launching the app, and a
/// view with its own tap gesture cannot serve as that button's label. Keeping
/// the *drawing* here is what stops the widget's checkbox from drifting away
/// from the app's.
struct TodoCheckboxShape: View {
    let state: CompletionState
    let tint: Color
    /// Which surface is drawing this, which sets the size.
    var scale: Theme.RowScale = .regular

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scale.checkboxCornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: 1.5)
                .frame(width: scale.checkboxSize, height: scale.checkboxSize)

            RoundedRectangle(cornerRadius: scale.checkboxCornerRadius, style: .continuous)
                .fill(fillColor)
                .frame(width: scale.checkboxSize, height: scale.checkboxSize)
                .opacity(state.isResolved ? 1 : 0)
                .scaleEffect(state.isResolved ? 1 : 0.5)

            // Half-fill marks "started" without claiming completion.
            if state == .started {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Palette.started)
                    .frame(width: scale.checkboxSize * 0.47, height: scale.checkboxSize * 0.47)
                    .transition(.scale.combined(with: .opacity))
            }

            if state == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: scale.glyphSize, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }

            if state == .cancelled {
                Image(systemName: "xmark")
                    .font(.system(size: scale.glyphSize * 0.91, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.toggle, value: state)
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

/// The checkbox in a todo row.
///
/// A tap toggles open/completed.
struct TodoCheckbox: View {
    let state: CompletionState
    let tint: Color
    let onToggle: () -> Void
    let onSelect: (CompletionState) -> Void
    var scale: Theme.RowScale = .regular

    @State private var isPressed = false

    var body: some View {
        // Not a `Button`: inside a `List` row the button's own long press is
        // forwarded to the row's context menu, so the status picker never
        // opens. Driving both gestures explicitly keeps them here.
        TodoCheckboxShape(state: state, tint: tint, scale: scale)
            .scaleEffect(isPressed ? 0.86 : 1)
            .animation(Theme.Animation.toggle, value: isPressed)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Status")
            .accessibilityValue(state.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .onTapGesture { onToggle() }
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

#Preview("Checkbox scales") {
    // The same box at all three sizes: the app list, the summary card, and the
    // widget. Proportions should read identically.
    VStack(alignment: .leading, spacing: 16) {
        ForEach(
            [
                ("Regular", Theme.RowScale.regular),
                ("Compact", .compact),
                ("Widget", .widget),
            ],
            id: \.0
        ) { name, scale in
            HStack(spacing: 12) {
                Text(name).font(.caption).frame(width: 70, alignment: .leading)
                ForEach(CompletionState.allCases, id: \.self) { state in
                    TodoCheckboxShape(state: state, tint: .blue, scale: scale)
                }
            }
        }
    }
    .padding()
}

#endif
