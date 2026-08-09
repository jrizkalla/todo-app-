import Testing
import Foundation
import SwiftUI
@testable import TODO

/// The to-do row is drawn by three separate view hierarchies — the main list,
/// the AI summary card, and the home screen widget. They cannot share a view
/// (the widget target has no access to the app's views), so they share
/// `Theme.RowScale` instead. These tests pin the relationships that make the
/// three read as one design, so a future tweak to one surface cannot silently
/// desynchronise them.
@MainActor
struct RowConsistencyTests {

    private let scales: [Theme.RowScale] = [.regular, .compact, .widget]

    /// Every surface draws a box, and it shrinks monotonically from list to
    /// widget rather than jumping around.
    @Test func checkboxShrinksFromListToWidget() {
        #expect(Theme.RowScale.regular.checkboxSize > Theme.RowScale.compact.checkboxSize)
        #expect(Theme.RowScale.compact.checkboxSize > Theme.RowScale.widget.checkboxSize)
    }

    /// The corner radius tracks the box size, so the shape reads the same at
    /// every scale instead of turning into a circle when small or a square when
    /// large.
    @Test func checkboxCornerRadiusStaysProportional() {
        let reference = Theme.Metrics.checkboxCornerRadius / Theme.Metrics.checkboxSize

        for scale in scales {
            let ratio = scale.checkboxCornerRadius / scale.checkboxSize
            #expect(abs(ratio - reference) < 0.0001, "\(scale) radius is out of proportion")
        }
    }

    /// The glyph inside a resolved box scales with the box too, so a checkmark
    /// never overflows the small widget box or rattles around in the large one.
    @Test func glyphStaysProportionalToTheBox() {
        for scale in scales {
            let ratio = scale.glyphSize / scale.checkboxSize
            #expect(abs(ratio - 11.0 / Theme.Metrics.checkboxSize) < 0.0001)
        }
    }

    /// The glyph always fits inside its box — the property that actually
    /// matters visually, independent of the ratio it is derived from.
    @Test func glyphFitsInsideTheBox() {
        for scale in scales {
            #expect(scale.glyphSize < scale.checkboxSize, "\(scale) glyph overflows its box")
        }
    }

    /// Gaps tighten in step with the boxes: a smaller surface is uniformly
    /// denser rather than mixing large gaps with small controls.
    @Test func spacingTightensWithScale() {
        #expect(Theme.RowScale.regular.horizontalSpacing >= Theme.RowScale.widget.horizontalSpacing)
        #expect(Theme.RowScale.regular.rowGap >= Theme.RowScale.widget.rowGap)
    }

    /// The list and the summary card share their row rhythm, which is what
    /// makes the summary read as a compact view of the same list.
    @Test func listAndSummaryShareRowRhythm() {
        #expect(Theme.RowScale.regular.horizontalSpacing == Theme.RowScale.compact.horizontalSpacing)
        #expect(Theme.RowScale.regular.rowGap == Theme.RowScale.compact.rowGap)
        #expect(Theme.RowScale.compact.rowGap == Theme.Metrics.rowGap)
    }

    /// Secondary text is never larger than the title it hangs off.
    @Test func metadataNeverOutweighsTheTitle() {
        // Fonts are opaque, so compare the semantic sizes these map to: every
        // surface pairs a title with caption-scale metadata, never the reverse.
        for scale in scales {
            #expect(scale.metadataFont == .caption2)
        }
        #expect(Theme.RowScale.regular.titleFont == .body)
        #expect(Theme.RowScale.compact.titleFont == .callout)
        #expect(Theme.RowScale.widget.titleFont == .caption)
    }

    /// All three render without crashing at their own scale.
    @Test func checkboxRendersAtEveryScaleAndState() {
        for scale in scales {
            for state in CompletionState.allCases {
                let renderer = ImageRenderer(
                    content: TodoCheckboxShape(state: state, tint: .blue, scale: scale)
                )
                #if os(macOS)
                #expect(renderer.nsImage != nil)
                #else
                #expect(renderer.uiImage != nil)
                #endif
            }
        }
    }
}
