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

        /// Corner radius of the floating Inbox panel.
        ///
        /// Matches `glassCard`'s default, so the panel and the summary cards
        /// are cut to the same curve rather than nearly the same one — a card
        /// that is close but not equal is more obviously wrong than one that is
        /// plainly different.
        static let panelCornerRadius: CGFloat = 20

        /// Gap between the floating panel and the window's edges.
        ///
        /// What makes the panel read as hovering *above* the content: with no
        /// inset it butts against the window frame and goes back to looking
        /// like a wall, however it is filled. Matched to the margin the summary
        /// column puts around its own cards, so the two sit on one grid — the
        /// panel is the same kind of object as the cards beside it, and a card
        /// inset differently from its neighbours is what reads as misaligned.
        static let panelInset: CGFloat = 16

        /// Corner radius of the checkbox, proportioned to its size so the two
        /// stay in step when either is retuned.
        static let checkboxCornerRadius: CGFloat = 5

        // MARK: Selected-row shadow

        /// Blur radius of the lift under an expanded row.
        ///
        /// Tighter than it used to be. A 20pt blur on a card this size reads as
        /// haze rather than as lift, and — because a shadow needs that much
        /// clear space on every side — it was also what made the row impossible
        /// to fit inside a `List` cell without being clipped.
        static let rowShadowRadius: CGFloat = 8
        static let rowShadowOpacity: Double = 0.14
        /// Pushed down slightly, so the card reads as lit from above rather
        /// than glowing evenly in all directions.
        static let rowShadowOffset: CGFloat = 2

        /// Clear space reserved around a row for its shadow to fall into.
        ///
        /// Derived from the shadow itself rather than eyeballed: the blur
        /// reaches roughly its radius in every direction, plus the downward
        /// offset. Too small and the `List` clips the blur square — which is
        /// exactly the artefact this exists to prevent — so the two numbers
        /// have to move together.
        static let rowShadowMargin: CGFloat = rowShadowRadius + rowShadowOffset

        /// Gap between consecutive to-do rows.
        ///
        /// The main list gets this as padding *inside* each row, since rows
        /// there are tappable cards that need the touch target; the summary
        /// card and the widget apply it as stack spacing. Either way the
        /// visual rhythm is the same.
        static let rowGap: CGFloat = 9

        // MARK: Platform-tuned

        /// Rows on a Mac are driven by a pointer, not a fingertip, so they lose
        /// the touch-target padding that makes the iOS list feel right and
        /// would make the Mac one look loose and half-empty.
        #if os(macOS)
        static let listRowVerticalPadding: CGFloat = 6
        static let listRowHorizontalPadding: CGFloat = 12
        /// Inset from the pane's edge to the row's card, matching the leading
        /// margin AppKit lists use.
        static let listContentMargin: CGFloat = 8
        #else
        static let listRowVerticalPadding: CGFloat = rowVerticalPadding
        static let listRowHorizontalPadding: CGFloat = rowHorizontalPadding * 2
        static let listContentMargin: CGFloat = 0
        #endif

        /// How far the focused row's card is inset from the row's own bounds.
        ///
        /// Derived from the content padding rather than set independently: the
        /// card has to sit a fixed distance *outside* the text to read as a
        /// container around it, so the two numbers cannot drift apart.
        static let listRowCardInset: CGFloat = listRowHorizontalPadding / 2

        /// The floating create button, sized for the input device.
        #if os(macOS)
        static let createButtonSize: CGFloat = 34
        static let createButtonGlyphSize: CGFloat = 15
        static let createButtonInset: CGFloat = 14
        #else
        static let createButtonSize: CGFloat = 52
        static let createButtonGlyphSize: CGFloat = 20
        static let createButtonInset: CGFloat = 22
        #endif

        /// Clearance below the last row so the floating button never covers it.
        #if os(macOS)
        static let listBottomClearance: CGFloat = 52
        #else
        static let listBottomClearance: CGFloat = 72
        #endif

        /// How far the app-wide create button sits above the tab bar.
        ///
        /// The button is an overlay on the whole `TabView`, whose frame runs
        /// underneath the bar, so it needs lifting clear of it by hand.
        #if os(macOS)
        static let createButtonTabBarClearance: CGFloat = 0
        #else
        static let createButtonTabBarClearance: CGFloat = 54
        #endif
    }

    /// A to-do row rendered at three different sizes.
    ///
    /// The same row appears in the main list, in the AI summary card, and in
    /// the home screen widget. They are three separate view hierarchies — the
    /// widget cannot import the app's views at all — so "consistent" has to
    /// mean *shared constants* rather than a shared view. Every size, gap, and
    /// font those three surfaces use comes from here, so a change lands in all
    /// three at once instead of drifting apart again.
    enum RowScale {
        /// The main list: full-size rows built for touch and inline editing.
        case regular
        /// The AI summary card: a glance, slightly tightened.
        case compact
        /// The widget: smallest, and constrained by the widget's own bounds.
        case widget

        /// Checkbox edge length.
        var checkboxSize: CGFloat {
            switch self {
            case .regular: Metrics.checkboxSize
            case .compact: 17
            case .widget: 15
            }
        }

        /// Checkbox corner radius, scaled with the box so the shape reads the
        /// same at every size rather than turning into a circle when small.
        var checkboxCornerRadius: CGFloat {
            checkboxSize / Metrics.checkboxSize * Metrics.checkboxCornerRadius
        }

        /// Gap between the checkbox and the title.
        var horizontalSpacing: CGFloat {
            switch self {
            case .regular, .compact: Metrics.rowSpacing
            case .widget: 8
            }
        }

        /// Gap between consecutive rows.
        var rowGap: CGFloat {
            switch self {
            case .regular, .compact: Metrics.rowGap
            case .widget: 7
            }
        }

        /// Title font.
        var titleFont: Font {
            switch self {
            case .regular: .body
            case .compact: .callout
            case .widget: .caption
            }
        }

        /// Trailing time badge, and other secondary metadata.
        var metadataFont: Font {
            switch self {
            case .regular, .compact: .caption2
            case .widget: .caption2
            }
        }

        /// The "+3 more" line closing a truncated list.
        ///
        /// One step down from the title, so it reads as a footnote to the list
        /// rather than as another row in it.
        var overflowFont: Font {
            switch self {
            case .regular, .compact: .caption
            case .widget: .caption2
            }
        }

        /// Weight of the checkmark and cross drawn inside a resolved box,
        /// proportioned to the box so they stay optically centred.
        var glyphSize: CGFloat {
            checkboxSize * 11 / Metrics.checkboxSize
        }
    }

    /// Motion, tuned to feel immediate rather than decorative.
    ///
    /// Four springs, from quickest to most substantial, and every animated
    /// change in the app picks one of them. The point is not that each is
    /// individually perfect but that they are *shared*: two surfaces animating
    /// the same kind of change at different speeds is what makes an interface
    /// feel loose, and it is the failure mode a per-call-site `.easeInOut`
    /// walks straight into.
    ///
    /// Responses are deliberately short. Anything past roughly 0.4s reads as
    /// the app thinking rather than the app responding.
    enum Animation {
        /// The quickest: a control acknowledging a press. Chips, badges, and
        /// anything whose change the finger is still on top of.
        static let quick: SwiftUI.Animation = .spring(response: 0.22, dampingFraction: 0.8)

        /// Checkbox and row state changes.
        static let toggle: SwiftUI.Animation = .spring(response: 0.26, dampingFraction: 0.72)

        /// Rows entering and leaving a list, and content swapping in place.
        static let listChange: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.85)

        /// A to-do row growing open to expose its notes, and closing again.
        ///
        /// Slightly longer and softer than `toggle`: this moves the rows below
        /// it down the screen, and a fast spring on that much travel reads as a
        /// jolt. The damping is just under critical, so the row settles with a
        /// hint of give — enough to feel like it grew rather than jumped, and
        /// short of the bounce that would make a list look springy.
        static let rowExpand: SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.82)

        /// The most substantial: panels, sheets, and moving between days.
        /// Still under a third of a second.
        static let panel: SwiftUI.Animation = .spring(response: 0.32, dampingFraction: 0.88)

        /// Suggestion chips appearing under a title field.
        static let suggestion: SwiftUI.Animation = .spring(response: 0.24, dampingFraction: 0.8)
    }

    enum Palette {
        static let accent = Color.accentColor
        static let overdue = Color.red
        static let started = Color.orange
        static let cancelled = Color.secondary
        /// Dot marking a to-do the user has not seen in its current list.
        static let unviewed = Color.yellow

        /// The color a space has until the user picks one.
        ///
        /// Named because it is also the model default (`Space.colorHex`), the
        /// fallback for a calendar with no color of its own, and what clearing
        /// the color picker returns to — those have to stay the same value, and
        /// as separate literals they were free to drift apart.
        static let defaultSpaceColor = "#8E8E93"

        /// Default colors offered when creating a space.
        static let spaceColors: [String] = [
            "#FF453A", "#FF9F0A", "#FFD60A", "#32D74B",
            "#64D2FF", "#0A84FF", "#BF5AF2", defaultSpaceColor,
        ]
    }
}

extension Color {
    /// Fill behind the expanded row's card.
    ///
    /// The system's own background colour rather than a literal white, so the
    /// card stays lighter than the list it sits on in *both* appearances — a
    /// hardcoded white card is invisible in light mode's white list and puts
    /// white text on a white field in dark mode.
    static var rowCard: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

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


extension Color {
    /// `#RRGGBB` for this color, or nil when its components cannot be resolved.
    ///
    /// The store keeps colors as hex strings to stay a CloudKit primitive, so a
    /// color coming back from SwiftUI's `ColorPicker` — which can be any color,
    /// not just one from the palette — has to be reduced to one before it is
    /// saved. Conversion goes through the sRGB space so a color picked in
    /// Display P3 still round-trips to a usable value.
    var hexString: String? {
        #if canImport(UIKit)
        typealias NativeColor = UIColor
        #elseif canImport(AppKit)
        typealias NativeColor = NSColor
        #else
        return nil
        #endif

        #if canImport(UIKit) || canImport(AppKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        #if canImport(UIKit)
        guard NativeColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        #else
        // `getRed` traps on AppKit colors that are not already RGB (pattern or
        // catalog colors), so convert first rather than asking.
        guard let converted = NativeColor(self).usingColorSpace(.sRGB) else { return nil }
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif

        // Clamp before scaling: extended-range color spaces produce components
        // outside 0...1, which would otherwise overflow the byte conversion.
        let clamp = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
        #endif
    }
}

extension Todo {
    /// Checkbox and accent color, from the todo's project or space.
    var color: Color {
        resolvedColorHex.map { Color(hex: $0) } ?? Theme.Palette.accent
    }
}
