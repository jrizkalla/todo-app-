import SwiftUI

/// The checkbox in a todo row.
///
/// A tap toggles open/completed. The spec's "hidden access method" for the
/// other two states is a long press, which opens a compact picker showing all
/// four states as icons.
struct TodoCheckbox: View {
    let state: CompletionState
    let tint: Color
    let onToggle: () -> Void
    let onSelect: (CompletionState) -> Void

    @State private var isPressed = false
    @State private var isShowingStatusPicker = false

    var body: some View {
        // Not a `Button`: inside a `List` row the button's own long press is
        // forwarded to the row's context menu, so the status picker never
        // opens. Driving both gestures explicitly keeps them here.
        checkbox
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Status")
            .accessibilityValue(state.label)
            .accessibilityHint("Double tap to toggle, long press to choose a status")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .onTapGesture { onToggle() }
            // KNOWN LIMITATION on iOS: inside a `List` row, the cell's
            // `UIContextMenuInteraction` claims the long press before anything
            // here sees it, so the picker does not open from the list — the
            // row's own menu appears instead. SwiftUI `highPriorityGesture`,
            // `simultaneousGesture`, and a UIKit recognizer overlay
            // (`LongPressCatcher`) were all tried and all lose to it.
            //
            // The picker itself works and is reachable everywhere the row has
            // no context menu. Resolving this needs either the row menu moved
            // off the long press, or the List cell's interaction disabled at
            // the UIKit level.
            .onLongPressGesture(minimumDuration: 0.35) {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                isShowingStatusPicker = true
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
            .popover(isPresented: $isShowingStatusPicker) {
                StatusPicker(current: state, tint: tint) { option in
                    isShowingStatusPicker = false
                    onSelect(option)
                }
                .presentationCompactAdaptation(.popover)
            }
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

/// The four states as a compact row of icons.
///
/// Icons rather than a text menu so the whole set fits in one glance beside the
/// row it belongs to, and the current state is marked rather than disabled —
/// tapping it is a harmless way to dismiss.
struct StatusPicker: View {
    let current: CompletionState
    let tint: Color
    let onSelect: (CompletionState) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CompletionState.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 20))
                            .foregroundStyle(color(for: option))
                            .frame(height: 24)

                        Text(option.label)
                            .font(.caption2)
                            .foregroundStyle(option == current ? .primary : .secondary)
                    }
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(option == current
                                  ? Color.secondary.opacity(0.16)
                                  : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option == current ? [.isSelected] : [])
            }
        }
        .padding(6)
    }

    /// Each state keeps the colour it has in the list, so the picker reads as
    /// the same vocabulary rather than a separate one.
    private func color(for option: CompletionState) -> Color {
        switch option {
        case .open: .secondary
        case .started: Theme.Palette.started
        case .completed: tint
        case .cancelled: Theme.Palette.cancelled
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

#Preview("Status picker") {
    // What the long press opens.
    StatusPicker(current: .started, tint: .blue) { _ in }
}
#endif
