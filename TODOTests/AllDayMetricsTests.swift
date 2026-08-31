import Testing
import CoreGraphics
@testable import TODO

/// Sizing of the calendar's all-day row.
///
/// The row is a `ScrollView`, so a cap computed smaller than the content it has
/// to hold does not scroll — it spills over the divider and the first hour of
/// the grid below. That was the bug these cover: the height came from a
/// hardcoded 22pt per chip, which was less than a chip actually measures.
struct AllDayMetricsTests {

    /// A chip height standing in for a measured one, deliberately unlike the
    /// old hardcoded constant so a regression to it would show up here.
    private let chipHeight: CGFloat = 25

    /// The row always has room for at least one chip, so an empty day is still
    /// a drop target rather than a zero-height sliver.
    @Test func emptyDayKeepsOneChipOfHeight() {
        let empty = AllDayMetrics.rowHeight(chipCount: 0, chipHeight: chipHeight)
        let one = AllDayMetrics.rowHeight(chipCount: 1, chipHeight: chipHeight)

        #expect(empty == one)
        #expect(empty == chipHeight + AllDayMetrics.rowPadding * 2)
    }

    /// The core invariant: below the cap, the row is tall enough for every chip
    /// it holds, the gaps between them, and its own padding. Anything less is
    /// the clipping this replaces.
    @Test(arguments: 1...AllDayMetrics.visibleChips)
    func rowFitsItsChipsBelowTheCap(count: Int) {
        let height = AllDayMetrics.rowHeight(chipCount: count, chipHeight: chipHeight)

        let content = CGFloat(count) * chipHeight
            + CGFloat(count - 1) * AllDayMetrics.chipSpacing
            + AllDayMetrics.rowPadding * 2

        #expect(height >= content)
    }

    /// Past the cap the row stops growing — that is what makes it scroll rather
    /// than push the hour grid off the bottom of the screen.
    @Test func rowStopsGrowingAtTheCap() {
        let atCap = AllDayMetrics.rowHeight(
            chipCount: AllDayMetrics.visibleChips,
            chipHeight: chipHeight
        )

        for count in (AllDayMetrics.visibleChips + 1)...(AllDayMetrics.visibleChips + 20) {
            #expect(AllDayMetrics.rowHeight(chipCount: count, chipHeight: chipHeight) == atCap)
        }
    }

    /// The row grows with the chips until it hits the cap, so a day holding two
    /// does not get the same slab of space as a day holding five.
    @Test func rowGrowsWithEachChipUpToTheCap() {
        let heights = (1...AllDayMetrics.visibleChips).map {
            AllDayMetrics.rowHeight(chipCount: $0, chipHeight: chipHeight)
        }

        for (shorter, taller) in zip(heights, heights.dropFirst()) {
            #expect(taller > shorter)
        }
    }

    /// A taller chip — a larger Dynamic Type size — has to produce a taller
    /// row. The old constant could not, which is why the row clipped as soon as
    /// text grew.
    @Test func tallerChipsMakeATallerRow() {
        let small = AllDayMetrics.rowHeight(chipCount: 3, chipHeight: 22)
        let large = AllDayMetrics.rowHeight(chipCount: 3, chipHeight: 40)

        #expect(large > small)
        #expect(large - small == 3 * (40 as CGFloat - 22))
    }

    /// The estimate is only used for the first layout pass, before a real chip
    /// has been measured. It has to clear the two things inside a chip that set
    /// its height — the caption line and the checkbox beside it — plus the
    /// chip's own padding. The old 22pt did not, which is what made the row
    /// spill on the very first frame.
    @Test func firstPassEstimateClearsAChipsOwnParts() {
        // Caption at the default text size, and the checkbox it sits next to.
        let captionLineHeight: CGFloat = 16
        let checkboxSize = Theme.RowScale.widget.checkboxSize

        let content = max(captionLineHeight, checkboxSize)
            + AllDayMetrics.chipPadding * 2

        #expect(AllDayMetrics.chipHeightEstimate >= content)
    }
}
