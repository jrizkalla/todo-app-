import SwiftUI

/// Where a dragged to-do would land, and whether to say so.
///
/// macOS only. A pointer drag hovers over a precise point for as long as the
/// user likes, so showing the landing position is useful and cheap to follow.
/// A touch drag has the finger over the very place the line would be drawn, and
/// the platform's own lift-and-reflow already answers the question, so iOS and
/// iPadOS keep the behaviour they have.
///
/// Split from the views so the arithmetic — which boundary a point is nearest,
/// and what the list looks like afterwards — can be tested without a drag
/// session, which is the part that cannot be driven from a test.
enum TodoDropIndicator {

    /// Whether a positional drop means anything in `destination`.
    ///
    /// The line is a promise that the to-do will land *there*, so it is only
    /// honest where the list has an order of its own to insert into.
    ///
    /// Search results are ranked by relevance and drawn from several lists at
    /// once, so a position among them describes nothing worth saving — the same
    /// reason `onMove` already refuses to reorder while searching. The Logbook
    /// is a record rather than a plan and refuses drops outright.
    static func showsLine(for destination: ListDestination, isSearching: Bool) -> Bool {
        guard !isSearching else { return false }
        switch destination {
        case .logbook: return false
        default: return true
        }
    }

    /// The gap the point `y` is nearest, as an index into `rowFrames`.
    ///
    /// Gaps are numbered like `Array` insertion offsets: 0 is above the first
    /// row, `count` is below the last. A point inside a row picks whichever of
    /// that row's own edges it is closer to, so the line tracks the pointer
    /// across a row's midpoint rather than waiting for it to clear the row.
    ///
    /// - Parameter rowFrames: each row's vertical extent in the list's own
    ///   coordinate space, in display order.
    static func insertionIndex(for y: CGFloat, in rowFrames: [ClosedRange<CGFloat>]) -> Int {
        guard !rowFrames.isEmpty else { return 0 }

        for (index, frame) in rowFrames.enumerated() {
            if y < frame.lowerBound { return index }
            if y <= frame.upperBound {
                let midpoint = (frame.lowerBound + frame.upperBound) / 2
                return y < midpoint ? index : index + 1
            }
        }
        return rowFrames.count
    }

    /// `todos` with `moved` taken out and put back at gap `index`.
    ///
    /// The gap is measured against the list *as shown*, which still contains the
    /// dragged row, so removing it first shifts every later gap up by one. Doing
    /// that arithmetic here is what stops a row dragged downwards from landing
    /// one position short — the off-by-one this function exists to own.
    ///
    /// - Returns: the new order, or `nil` when the move would change nothing,
    ///   so a caller can skip a write and an undo entry for a no-op drag.
    static func reordering(
        _ todos: [Todo],
        moving moved: Todo,
        to index: Int
    ) -> [Todo]? {
        guard let from = todos.firstIndex(where: { $0.uuid == moved.uuid }) else { return nil }

        let clamped = min(max(index, 0), todos.count)
        // Dropping into either gap touching the row's current home leaves the
        // order alone: the row is already between those two neighbours.
        if clamped == from || clamped == from + 1 { return nil }

        var reordered = todos
        reordered.remove(at: from)
        reordered.insert(moved, at: clamped > from ? clamped - 1 : clamped)
        return reordered
    }
}

/// The list's own coordinate space, which row frames and the pointer's drop
/// location are both measured in so they can be compared.
extension CoordinateSpace {
    static let todoList = "TodoListView.rows"
}

extension View {
    /// Record this row's vertical extent for the drop indicator's arithmetic.
    ///
    /// A no-op away from macOS, where there is no line to place — the frames
    /// would be measured on every layout pass and never read.
    func reportsRowFrame(
        for id: UUID,
        into frames: Binding<[UUID: ClosedRange<CGFloat>]>
    ) -> some View {
        #if os(macOS)
        return onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(CoordinateSpace.todoList))
        } action: { frame in
            // A row mid-animation can report an inverted or empty rect, which
            // `ClosedRange` traps on rather than tolerates.
            guard frame.height > 0 else { return }
            frames.wrappedValue[id] = frame.minY...frame.maxY
        }
        .onDisappear {
            // Or a scrolled-away row keeps claiming a gap that is no longer on
            // screen, and the line snaps to a position nothing occupies.
            frames.wrappedValue[id] = nil
        }
        #else
        return self
        #endif
    }
}

/// A drawn drop line: where it sits, and the dragged row's colour.
///
/// `Equatable` so the list can animate the line between gaps rather than have
/// it jump, and so a hover that does not change the gap costs no redraw.
struct DropIndicatorPosition: Equatable {
    let y: CGFloat
    let color: Color
    /// Which gap this line stands for, kept so the drop can reorder to exactly
    /// the position the user was shown.
    let index: Int
}

/// The line itself: where it sits between rows, and what it looks like.
///
/// Drawn as an overlay on the list rather than as a row of its own, so showing
/// it never reflows the rows underneath — a list that shifted as the line moved
/// between gaps would fight the pointer.
struct TodoDropIndicatorLine: View {
    /// Where the line sits, and the dragged to-do's own colour — so the line
    /// reads as *that* row's destination rather than as generic chrome.
    let position: DropIndicatorPosition

    /// Thick enough to read as a deliberate mark at a glance, thin enough not
    /// to look like a row in its own right.
    private let thickness: CGFloat = 2

    var body: some View {
        Capsule()
            .fill(position.color)
            .frame(height: thickness)
            // Inset to the rows' own margin. Run edge to edge it reads as a
            // section divider rather than as a place a row is about to go.
            .padding(.horizontal, Theme.Metrics.listRowHorizontalPadding)
            // Centred on the gap rather than hanging below it.
            .offset(y: position.y - thickness / 2)
            .frame(maxHeight: .infinity, alignment: .top)
            // The line marks a position; it must never eat the drop itself.
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
