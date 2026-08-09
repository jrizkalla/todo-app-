import Foundation

/// Where one block sits within a day column, as fractions of the column width.
struct CalendarSlot: Equatable {
    /// Left edge, 0 to 1.
    let offset: Double
    /// Width, 0 to 1.
    let width: Double
    /// Draw order within a cluster; higher sits on top.
    ///
    /// Only meaningful for cascaded blocks, which deliberately overlap and so
    /// need a defined stacking order rather than relying on view order.
    var depth: Int = 0
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

    /// How far each successive cascaded block is pushed in, as a fraction of
    /// the column width. Matches the shallow step Calendar.app uses: enough to
    /// show the block underneath, not so much that the title is squeezed out.
    private static let cascadeStep = 0.12

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

                // Blocks sharing a column with an earlier one they overlap are
                // cascaded rather than split: Calendar.app insets each later
                // start and draws it on top, which keeps both titles legible
                // where an equal split would shrink them to nothing.
                let depth = cascadeDepth(of: block, in: cluster, columnOf: columnOf)
                let inset = Double(depth) * cascadeStep * unit

                result[block.id] = CalendarSlot(
                    offset: Double(column) * unit + inset,
                    width: max(Double(span) * unit - inset, unit * 0.25),
                    depth: depth
                )
            }
        }

        return result
    }

    /// How many overlapping blocks this one is stacked on top of.
    ///
    /// Counts blocks in the same or an earlier column that start strictly
    /// sooner, since those are the ones already occupying this block's left
    /// edge. Simultaneous starts do not cascade — neither is "on top" of the
    /// other, so the column split alone separates them.
    private static func cascadeDepth(
        of block: Block,
        in cluster: [Block],
        columnOf: [String: Int]
    ) -> Int {
        guard let column = columnOf[block.id] else { return 0 }

        return cluster.filter {
            guard let other = columnOf[$0.id], $0.id != block.id else { return false }
            return other <= column && $0.start < block.start && overlaps($0, block)
        }.count
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
