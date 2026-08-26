import SwiftUI

/// The pieces the "When?" and "Repeat" panels are both built from.
///
/// Extracted rather than duplicated because the two panels are meant to read as
/// one family: they are raised by the same kinds of gesture, presented at the
/// same detents, and a user moving between them should see the same header, the
/// same tappable rows, and the same destructive footer — only the question at
/// the top changing. Two hand-matched copies would drift the first time either
/// was touched.
enum SchedulePickerParts {

    /// The centered title with a close button hung on the trailing edge.
    struct Header: View {
        let title: String
        let onDismiss: () -> Void

        var body: some View {
            HStack {
                Spacer()
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 12)
        }
    }

    /// A quiet all-caps group label, for panels with more than one group.
    ///
    /// The schedule panel has no need of these — its rows are self-describing —
    /// but the repeat panel stacks four distinct groups and would read as an
    /// undifferentiated pile of controls without them.
    struct SectionLabel: View {
        let text: String

        init(_ text: String) { self.text = text }

        var body: some View {
            Text(text.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
    }

    /// One tappable row: tinted glyph, title, optional explanation, checkmark.
    ///
    /// The `subtitle` is what lets the repeat panel put each mode's meaning
    /// under its name; the schedule panel passes nil and gets exactly the row
    /// it had before.
    struct Shortcut: View {
        let title: String
        var subtitle: String?
        let symbol: String
        let tint: Color
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 8)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// The full-width capsule at the foot of a panel — "Clear", "Stop
    /// Repeating" — in the red that marks it as the undoing action.
    struct DestructiveButton: View {
        let title: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        Capsule().fill(Color.red.opacity(0.85))
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    /// A small tinted glyph, sized to line up with `Shortcut`'s.
    static func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .frame(width: 22)
    }
}
