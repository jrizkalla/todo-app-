import SwiftUI

/// Swatch grid for choosing a space or project color.
///
/// A fixed palette rather than a full color well: these colors are used as
/// checkbox tints and calendar fills, and a curated set keeps them legible in
/// both light and dark appearances.
struct ColorSwatchPicker: View {
    /// Selected color as `#RRGGBB`. Nil means "inherit" when `allowsNoColor`.
    @Binding var selection: String?
    /// Offers a "no color" option, used by projects to fall back to their space.
    var allowsNoColor: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 42), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            if allowsNoColor {
                swatch(hex: nil)
            }
            ForEach(Theme.Palette.spaceColors, id: \.self) { hex in
                swatch(hex: hex)
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(hex: String?) -> some View {
        let isSelected = selection?.caseInsensitiveCompare(hex ?? "") == .orderedSame
            || (hex == nil && selection == nil)

        return Button {
            withAnimation(Theme.Animation.toggle) { selection = hex }
        } label: {
            ZStack {
                Circle()
                    .fill(hex.map { Color(hex: $0) } ?? Color.secondary.opacity(0.22))
                    .frame(width: 30, height: 30)

                // The inherit swatch needs a glyph, since it has no color of
                // its own to recognize.
                if hex == nil {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.65), lineWidth: 2)
                        .frame(width: 38, height: 38)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? "Inherit color" : "Color \(hex!)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    @Previewable @State var color: String? = Theme.Palette.spaceColors.first
    return Form {
        Section("Color") {
            ColorSwatchPicker(selection: $color, allowsNoColor: true)
        }
    }
}
