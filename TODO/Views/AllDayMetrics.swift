import CoreGraphics

/// Sizing rules for the calendar's all-day row.
///
/// Split out of `CalendarView` so the arithmetic that decides how tall the row
/// is allowed to get can be checked directly. That arithmetic is not cosmetic:
/// the row is a `ScrollView`, and a cap computed *smaller* than the content it
/// has to hold does not scroll — it spills, painting the chips over the divider
/// and the first hour of the grid beneath.
enum AllDayMetrics {

    /// How many chips the row shows before it starts scrolling.
    static let visibleChips = 5

    /// Vertical padding inside one chip, above and below its content.
    static let chipPadding: CGFloat = 3

    /// Gap between two stacked chips.
    static let chipSpacing: CGFloat = 4

    /// Padding above and below the row as a whole.
    static let rowPadding: CGFloat = 6

    /// Height assumed for one chip until a real one has been measured.
    ///
    /// The row used to size itself from a hardcoded 22pt for good, which was
    /// already short of what a chip measures at the default text size and fell
    /// further behind at every larger one — the clipping this replaces. The
    /// estimate now only covers the first layout pass, before `CalendarView`'s
    /// probe reports a real height, and it deliberately errs tall: a cap that
    /// starts slightly generous tightens a frame later, where one that starts
    /// short clips the grid for that frame.
    static let chipHeightEstimate: CGFloat = 26

    /// Height the row is capped at, for `chipCount` chips of `chipHeight` each.
    ///
    /// The cap is a maximum, not a size — a day holding one chip gets a row one
    /// chip tall. Beyond `visibleChips` the row stops growing and scrolls.
    static func rowHeight(chipCount: Int, chipHeight: CGFloat) -> CGFloat {
        let rows = min(max(chipCount, 1), visibleChips)
        return CGFloat(rows) * chipHeight
            + CGFloat(max(rows - 1, 0)) * chipSpacing
            + rowPadding * 2
    }
}
