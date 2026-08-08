import SwiftUI

/// The checkbox in a todo row.
///
/// A tap toggles open/completed. The spec's "hidden access method" for the
/// other two states is a long press, which opens a menu offering Started and
/// Cancelled.
struct TodoCheckbox: View {
    let state: CompletionState
    let tint: Color
    let onToggle: () -> Void
    let onSelect: (CompletionState) -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onToggle) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status")
        .accessibilityValue(state.label)
        // The long-press menu is the discoverable route to started/cancelled.
        .contextMenu {
            ForEach(CompletionState.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Label(option.label, systemImage: option.symbolName)
                }
                .disabled(option == state)
            }
        }
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
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

#Preview {
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
