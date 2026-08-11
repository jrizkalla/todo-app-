import SwiftUI

/// The status options behind a checkbox's long press.
///
/// Offers every state *except* the current one — picking the state a to-do is
/// already in is a no-op, and listing it invites the tap that does nothing.
struct StatusPicker: View {
    let current: CompletionState
    let tint: Color
    let onSelect: (CompletionState) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CompletionState.allCases.filter { $0 != current }, id: \.self) { option in
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
                        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
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
#Preview("Status picker") {
    // What the long press opens.
    StatusPicker(current: .started, tint: .blue) { _ in }
}
#endif
