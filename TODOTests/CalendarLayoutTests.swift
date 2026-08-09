import Testing
import Foundation
@testable import TODO

/// Side-by-side placement of overlapping calendar blocks.
struct CalendarLayoutTests {

    private let base = Date(timeIntervalSince1970: 1_754_000_000)

    private func block(_ id: String, startHour: Double, hours: Double) -> CalendarLayout.Block {
        let start = base.addingTimeInterval(startHour * 3600)
        return .init(id: id, start: start, end: start.addingTimeInterval(hours * 3600))
    }

    @Test func emptyInputProducesNoSlots() {
        #expect(CalendarLayout.slots(for: []).isEmpty)
    }

    /// A lone block uses the whole column.
    @Test func singleBlockFillsTheWidth() {
        let slots = CalendarLayout.slots(for: [block("a", startHour: 9, hours: 1)])

        #expect(slots["a"] == CalendarSlot(offset: 0, width: 1))
    }

    /// Two blocks at the same hour split the column.
    @Test func twoOverlappingBlocksSplitTheColumn() {
        let slots = CalendarLayout.slots(for: [
            block("a", startHour: 9, hours: 1),
            block("b", startHour: 9, hours: 1),
        ])

        #expect(slots["a"] == CalendarSlot(offset: 0, width: 0.5))
        #expect(slots["b"] == CalendarSlot(offset: 0.5, width: 0.5))
    }

    /// Three mutually overlapping blocks each take a third.
    @Test func threeOverlappingBlocksSplitInThirds() {
        let slots = CalendarLayout.slots(for: [
            block("a", startHour: 15, hours: 1),
            block("b", startHour: 15, hours: 1),
            block("c", startHour: 15, hours: 1),
        ])

        for id in ["a", "b", "c"] {
            #expect(abs((slots[id]?.width ?? 0) - 1.0 / 3) < 0.0001)
        }
        #expect(Set(slots.values.map(\.offset).map { ($0 * 3).rounded() }) == [0, 1, 2])
    }

    /// Blocks that merely touch — one ends as the next starts — do not overlap,
    /// so both keep the full width.
    @Test func adjacentBlocksDoNotSplit() {
        let slots = CalendarLayout.slots(for: [
            block("a", startHour: 9, hours: 1),
            block("b", startHour: 10, hours: 1),
        ])

        #expect(slots["a"] == CalendarSlot(offset: 0, width: 1))
        #expect(slots["b"] == CalendarSlot(offset: 0, width: 1))
    }

    /// A morning collision must not narrow an unrelated afternoon block.
    @Test func separateClustersAreLaidOutIndependently() {
        let slots = CalendarLayout.slots(for: [
            block("morning1", startHour: 9, hours: 1),
            block("morning2", startHour: 9, hours: 1),
            block("afternoon", startHour: 15, hours: 1),
        ])

        #expect(slots["morning1"]?.width == 0.5)
        #expect(slots["afternoon"] == CalendarSlot(offset: 0, width: 1))
    }

    /// A block reuses a column once its previous occupant has ended.
    @Test func columnsAreReusedAfterABlockEnds() {
        // `long` spans all three hours; `a` and `b` sit in the second column
        // one after the other.
        let slots = CalendarLayout.slots(for: [
            block("long", startHour: 9, hours: 3),
            block("a", startHour: 9, hours: 1),
            block("b", startHour: 10, hours: 1),
        ])

        // Ties on start time break by the shorter block first, so `a` takes
        // column 0 and `long` takes column 1.
        #expect(slots["a"]?.offset == 0)
        #expect(slots["long"]?.offset == 0.5)
        // `b` starts exactly when `a` ends, so it reclaims the same column
        // rather than forcing a third.
        #expect(slots["b"]?.offset == 0)
        #expect(slots["b"]?.width == 0.5)
    }

    /// Every block gets a slot, and none escapes the column.
    @Test func slotsStayWithinTheColumn() {
        let blocks = (0..<6).map { block("b\($0)", startHour: 9 + Double($0) * 0.25, hours: 1) }
        let slots = CalendarLayout.slots(for: blocks)

        #expect(slots.count == blocks.count)
        for slot in slots.values {
            #expect(slot.offset >= 0)
            #expect(slot.width > 0)
            #expect(slot.offset + slot.width <= 1.0001)
        }
    }
}
