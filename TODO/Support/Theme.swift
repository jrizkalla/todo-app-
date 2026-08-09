import SwiftUI

/// Shared visual constants, tuned toward the calm, airy feel of Things:
/// generous spacing, restrained color, and short spring animations.
enum Theme {
    enum Metrics {
        static let rowSpacing: CGFloat = 10
        static let rowVerticalPadding: CGFloat = 9
        static let rowHorizontalPadding: CGFloat = 7
        static let checkboxSize: CGFloat = 19
        static let cornerRadius: CGFloat = 8
        static let sectionSpacing: CGFloat = 22
        static let sidebarWidth: CGFloat = 248
        static let sidePanelWidth: CGFloat = 300
    }

    enum Animation {
        /// Checkbox and row state changes.
        static let toggle: SwiftUI.Animation = .spring(response: 0.32, dampingFraction: 0.7)
        /// Rows entering and leaving a list.
        static let listChange: SwiftUI.Animation = .spring(response: 0.38, dampingFraction: 0.82)
        /// Panels and sheets.
        static let panel: SwiftUI.Animation = .spring(response: 0.42, dampingFraction: 0.86)
        /// Suggestion chips appearing under a title field.
        static let suggestion: SwiftUI.Animation = .spring(response: 0.28, dampingFraction: 0.78)
    }

    enum Palette {
        static let accent = Color.accentColor
        static let overdue = Color.red
        static let started = Color.orange
        static let cancelled = Color.secondary
        /// Dot marking a to-do the user has not seen in its current list.
        static let unviewed = Color.yellow

        /// Default colors offered when creating a space.
        static let spaceColors: [String] = [
            "#FF453A", "#FF9F0A", "#FFD60A", "#32D74B",
            "#64D2FF", "#0A84FF", "#BF5AF2", "#8E8E93",
        ]
    }
}

extension Color {
    /// Build a color from a `#RRGGBB` string, falling back to gray on bad input.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}


extension Todo {
    /// Checkbox and accent color, from the todo's project or space.
    var color: Color {
        resolvedColorHex.map { Color(hex: $0) } ?? Theme.Palette.accent
    }
}
