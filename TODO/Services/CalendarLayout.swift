import Foundation

/// Where one block sits within a day column, as fractions of the column width.
struct CalendarSlot: Equatable {
    /// Left edge, 0 to 1.
    let offset: Double
    /// Width, 0 to 1.
    let width: Double
}

/// Arranges overlapping blocks side by side, the way Calendar.app does.
///
/// Without this, two events at the same hour draw on top of each other and only
/// the last one is readable. Blocks are grouped into runs of mutual overlap;
/// each run is split into columns, and a block spans any adjacent free columns
/// so a lone event still fills the width.
enum CalendarLayout {

    /// Anything that occupies a time range.
    struct Block: Identifiable {
        let id: String
        let start: Date
        let end: Date
    }

    /// Slots keyed by block id.
    static func slots(for blocks: [Block]) -> [String: CalendarSlot] {
        guard !blocks.isEmpty else { return [:] }

        let ordered = blocks.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        var result: [String: CalendarSlot] = [:]

        for cluster in clusters(of: ordered) {
            // Greedy column packing: a block takes the first column whose last
            // occupant has already ended.
            var columnEnds: [Date] = []
            var columnOf: [String: Int] = [:]

            for block in cluster {
                if let free = columnEnds.firstIndex(where: { $0 <= block.start }) {
                    columnEnds[free] = block.end
                    columnOf[block.id] = free
                } else {
                    columnEnds.append(block.end)
                    columnOf[block.id] = columnEnds.count - 1
                }
            }

            let columnCount = max(columnEnds.count, 1)
            let unit = 1.0 / Double(columnCount)

            for block in cluster {
                guard let column = columnOf[block.id] else { continue }

                // Widen into following columns that nothing overlapping uses,
                // so a block never leaves dead space beside it.
                var span = 1
                var next = column + 1
                while next < columnCount,
                      !cluster.contains(where: {
                          columnOf[$0.id] == next && overlaps($0, block)
                      }) {
                    span += 1
                    next += 1
                }

                result[block.id] = CalendarSlot(
                    offset: Double(column) * unit,
                    width: Double(span) * unit
                )
            }
        }

        return result
    }

    /// Split into runs where each block overlaps at least one other in the run.
    ///
    /// Laying out each run independently keeps an afternoon collision from
    /// narrowing an unrelated morning event.
    private static func clusters(of ordered: [Block]) -> [[Block]] {
        var clusters: [[Block]] = []
        var current: [Block] = []
        var currentEnd: Date?

        for block in ordered {
            if let end = currentEnd, block.start < end {
                current.append(block)
                currentEnd = max(end, block.end)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [block]
                currentEnd = block.end
            }
        }
        if !current.isEmpty { clusters.append(current) }

        return clusters
    }

    private static func overlaps(_ a: Block, _ b: Block) -> Bool {
        a.start < b.end && b.start < a.end
    }
}
