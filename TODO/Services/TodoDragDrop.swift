import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A to-do being dragged between surfaces.
///
/// Carries the `uuid` rather than the model object: a `Todo` is a SwiftData
/// object bound to a context and cannot cross a drag session, whereas the uuid
/// is stable and the receiver already has the store to look it up in.
///
/// Registered under its own content type rather than as plain text so a drag
/// from the Inbox is not accepted by every text field in the app, and so a
/// stray string dragged in from outside is not mistaken for a to-do.
struct TodoTransfer: Codable, Transferable {
    let uuid: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .todoItem)
    }
}

extension UTType {
    /// Declared in the app's Info.plist as an exported type.
    static let todoItem = UTType(exportedAs: "com.johnrizkalla.app.TODO.todo-item")
}

/// The to-do currently being dragged, within this process.
///
/// A drop target can only get the payload out of an `NSItemProvider`
/// asynchronously, which is fine for the drop itself but too slow for anything
/// that has to follow the pointer: the macOS drop line would trail the cursor
/// by a frame or more, and would have no colour at all until the first load
/// returned. The drag source already knows which to-do it is, so it records it
/// here as the drag begins.
///
/// Deliberately not a substitute for the payload. A drag from *another*
/// window or app leaves this `nil`, and every drop still reads the transfer it
/// was handed — this only decorates a drag already in flight.
///
/// A drag released outside every target leaves the last value behind, since
/// there is no drop to clear it. That is harmless: nothing reads it except
/// while a drag is over a list, by which point the next drag has overwritten
/// it, and the line only draws for a row the list in question actually holds.
///
/// Deliberately *not* `@Observable`. This is written from inside the drag
/// preview's builder, and observable writes there invalidate every view that
/// reads the property — including the list the drag started from, whose
/// subtree owns the drag session. Rebuilding that subtree mid-lift cancels the
/// drag before it leaves the row, which is the same identity churn the note on
/// `TodoDraggableModifier` describes, arriving by way of observation rather
/// than view type. Every reader polls it imperatively during a drag it is
/// already tracking, so there is nothing here worth observing.
@MainActor
final class ActiveDrag {
    static let shared = ActiveDrag()

    private(set) var todo: Todo?

    private init() {}

    func begin(_ todo: Todo) {
        self.todo = todo
    }

    func end() {
        todo = nil
    }
}

/// What dropping a to-do somewhere should do to it.
///
/// Written as one function so every drop target agrees on the meaning of a
/// destination. The rules follow what each list *is*, so that a to-do dropped
/// somewhere afterwards actually appears there — dropping onto Today without
/// setting a date would file it and then leave it invisible in the list the
/// user just dropped it on, which reads as the drop having failed.
enum TodoDropAction {
    /// File `todo` as though it belonged to `destination`.
    ///
    /// - Returns: `false` when the destination cannot accept a drop, so the
    ///   caller can refuse it rather than silently doing nothing.
    /// Resolves the drop target by predicate through `store.context`, rather
    /// than by scanning caller-supplied arrays of every to-do and space — a
    /// drop needs exactly one row, and fetching it is what the identifier is
    /// for.
    @discardableResult
    static func apply(
        _ destination: ListDestination,
        to todo: Todo,
        store: TodoStore,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Bool {
        // A drop is recorded as one undoable action even where it takes several
        // store verbs to carry out — dropping onto the Inbox clears the date
        // *and* the parent *and* the space, and undoing that should put the row
        // back in one step rather than three.
        //
        // Wrapped around the whole switch rather than repeated per case so a
        // destination added later is undoable by construction.
        var moved = false
        store.recordingUndo(dropName(for: destination), on: todo) {
            moved = applyMove(destination, to: todo, store: store, calendar: calendar, now: now)
        }
        return moved
    }

    /// What the undo entry for a drop onto `destination` is called.
    private static func dropName(for destination: ListDestination) -> String {
        switch destination {
        case .today, .tomorrow, .thisWeek, .nextWeek: "Schedule"
        case .inbox, .anytime: "Unschedule"
        default: "Move"
        }
    }

    private static func applyMove(
        _ destination: ListDestination,
        to todo: Todo,
        store: TodoStore,
        calendar: Calendar,
        now: Date
    ) -> Bool {
        switch destination {
        case .inbox:
            // The Inbox is "unfiled": no home and no date is what puts a to-do
            // there, so dropping onto it has to clear both — the week plan
            // included, since that is a date by another name and would file the
            // row straight back out into Anytime.
            store.update(todo) {
                $0.assignedDate = nil
                $0.assignedHasTime = false
                $0.clearWeekSchedule()
            }
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: nil)
            return true

        case .today:
            store.update(todo) {
                $0.assignedDate = moveToDay(
                    calendar.startOfDay(for: now), keepingTimeOf: $0, calendar: calendar
                )
                // A day beats the week it was planned for. Dropping onto a
                // dated list is the user answering "when" more precisely than
                // they had, so the vaguer answer goes rather than sitting
                // alongside it — see `Todo.scheduleForWeek`.
                $0.clearWeekSchedule()
            }
            return true

        case .tomorrow:
            store.update(todo) {
                $0.assignedDate = moveToDay(
                    calendar.startOfDay(for: now).addingTimeInterval(24 * 3600),
                    keepingTimeOf: $0,
                    calendar: calendar
                )
                $0.clearWeekSchedule()
            }
            return true

        case .thisWeek:
            // Now that the list is backed by a real field, a drop onto it means
            // what it says: plan this for the week, and leave the day open.
            // It used to date the item to today, which was a guess forced by
            // there being nowhere else to put the intent — the row then showed
            // up in Today as well, claiming a day the user had not chosen.
            store.update(todo) {
                $0.scheduleForWeek(.thisWeek, now: now, calendar: calendar)
            }
            return true

        case .nextWeek:
            store.update(todo) {
                $0.scheduleForWeek(.nextWeek, now: now, calendar: calendar)
            }
            return true

        case .anytime:
            // Anytime means scheduled-but-undated, and a week plan is a date
            // in every way that matters here — leaving it on would keep the row
            // in This Week, which is not where it was just dropped.
            store.update(todo) {
                $0.assignedDate = nil
                $0.assignedHasTime = false
                $0.clearWeekSchedule()
            }
            return true

        case .space(let id):
            guard let space = TodoQueries.space(uuid: id, in: store.context) else { return false }
            // Leaves any parent behind: a to-do belongs to one container, and
            // keeping the old parent would file it into a project that may sit
            // in a different space entirely.
            store.move(todo, toParent: nil)
            store.move(todo, toSpace: space)
            return true

        case .project(let id):
            guard let project = TodoQueries.todo(uuid: id, in: store.context),
                  project.uuid != todo.uuid
            else { return false }
            return store.adopt(todo, asSubtaskOf: project)

        case .logbook:
            // The Logbook is a record of finished work, not a place to file
            // something. Completing a to-do by dropping it here would be a
            // destructive act triggered by a slip of the mouse.
            return false
        }
    }

    /// Re-date a to-do onto `day`, keeping its time of day when it had one.
    ///
    /// Dropping onto Today answers *which day*, not *what time* — a 9am standup
    /// dragged from This Week into Today is still a 9am standup. Flattening it
    /// to midnight silently threw away a time the user had set, and moved the
    /// item off the calendar grid into the all-day row as a side effect of a
    /// gesture that said nothing about either.
    private static func moveToDay(
        _ day: Date,
        keepingTimeOf todo: Todo,
        calendar: Calendar
    ) -> Date {
        guard todo.assignedHasTime, let existing = todo.assignedDate else { return day }

        let time = calendar.dateComponents([.hour, .minute], from: existing)
        return calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day
        ) ?? day
    }

    /// Whether a destination will accept a drop at all.
    ///
    /// Used to refuse the drag up front, so the cursor does not promise a drop
    /// that will be thrown away.
    static func accepts(_ destination: ListDestination, todo: Todo) -> Bool {
        switch destination {
        case .logbook:
            false
        case .project(let id):
            // A project cannot be dropped into itself.
            id != todo.uuid
        default:
            true
        }
    }
}

extension View {
    /// Accept to-dos dropped onto a list destination.
    ///
    /// Wrapped as a modifier because four different surfaces need identical
    /// behaviour — the sidebar rows, the list pane, and the calendar's all-day
    /// row — and the highlight-while-targeted half is easy to leave out when
    /// each writes its own.
    ///
    /// Every surface takes exactly one `dropDestination` and nothing layered
    /// over it. A second drop target on the same view — even one that only
    /// wanted to watch the pointer go past — takes the drag away from this one
    /// on macOS, which is what stopped drags from a list reaching the sidebar.
    func todoDropTarget(
        _ destination: ListDestination,
        store: TodoStore,
        isTargeted: Binding<Bool>? = nil
    ) -> some View {
        modifier(
            TodoDropTargetModifier(
                destination: destination,
                store: store,
                externalTargeting: isTargeted
            )
        )
    }

    /// Make a to-do draggable to another list or onto the calendar.
    ///
    /// `isEnabled` must never add or remove `draggable` itself — see
    /// `TodoDraggableModifier` for why, and for what suppresses the drag
    /// instead.
    func todoDraggable(_ todo: Todo, isEnabled: Bool = true) -> some View {
        modifier(TodoDraggableModifier(todo: todo, isEnabled: isEnabled))
    }
}

/// Attaches the drag source with a view type that does not change when the row
/// gains or loses focus.
///
/// `draggable` is attached unconditionally. This previously hung the app: a
/// `@ViewBuilder` `if isEnabled` produced two structurally different view
/// types, so every flip of the flag changed this subtree's identity and made
/// SwiftUI tear the whole thing down — including the row's `TextField`. That
/// field is what holds focus, so destroying it cleared `focusedTodoID`, which
/// flipped `isEnabled` back, which rebuilt the field, which took focus again.
/// The row oscillated inside a single layout pass: the main thread never
/// returned, and each turn allocated a fresh subtree, so memory climbed until
/// the OS killed the app. It reproduced on the second tap of a row — the tap
/// that first moves focus into the title.
///
/// The gesture is suppressed instead, which keeps one stable view type across
/// the flip. That still serves the original reason for the branch: a drag
/// gesture that exists but declines to start would swallow the press it was
/// offered, and a focused title has to keep its press for caret placement and
/// text selection.

/// How large the drag preview draws.
///
/// Split out of the modifier so the fallback can be tested: the rule only
/// matters in the cases that are awkward to reach by hand — the first layout
/// pass, before the row has been measured at all.
enum DragPreviewSize {
    /// How much of the row's width the preview takes.
    ///
    /// Slightly under the row so the thing in flight reads as lifted away from
    /// the list rather than as a slab sitting exactly on top of it.
    static let widthFraction: CGFloat = 0.9

    /// How much of the row's height the preview takes.
    ///
    /// Tighter than the width: a row's height includes the metadata line under
    /// the title, which the preview does not draw, so there is more to give up
    /// vertically than horizontally.
    static let heightFraction: CGFloat = 0.8

    /// The size the preview should adopt for a row measured at `rowSize`.
    ///
    /// A `nil` dimension means "size to your own content", which is the
    /// pre-existing behaviour and the right answer before a real measurement
    /// arrives. A dimension reported as zero or negative is not something
    /// anyone can see, and matching it would draw an invisible preview.
    ///
    /// The two axes are resolved independently: the first layout pass can
    /// report a sensible width alongside a zero height, and half a measurement
    /// is still worth using.
    static func forRow(measuring rowSize: CGSize?) -> (width: CGFloat?, height: CGFloat?) {
        (
            usable(rowSize?.width).map { $0 * widthFraction },
            usable(rowSize?.height).map { $0 * heightFraction }
        )
    }

    private static func usable(_ dimension: CGFloat?) -> CGFloat? {
        guard let dimension, dimension > 0 else { return nil }
        return dimension
    }
}

private struct TodoDraggableModifier: ViewModifier {
    let todo: Todo
    let isEnabled: Bool

    /// The on-screen size of the row this modifier is attached to, handed to
    /// the preview so the thing that lifts off matches the thing it lifted
    /// from. Without it the preview shrinks to fit its own title and the row
    /// appears to collapse the instant the drag begins.
    @State private var rowSize: CGSize?

    func body(content: Content) -> some View {
        content
            .draggable(TodoTransfer(uuid: todo.uuid)) {
                // Recorded as the preview is built, because that is the one
                // place the lifting row identifies itself. Deliberately *not* a
                // gesture of its own: this row's press handling is load-bearing
                // and fragile — see the note above this type — and the drop
                // line is not worth risking it for.
                //
                // SwiftUI may build the preview more than once; writing the
                // same value again is harmless. It is the drop targets that
                // clear the record, so a stale one cannot outlive a drag.
                TodoDragPreview(todo: todo, rowSize: rowSize)
                    .onAppear { ActiveDrag.shared.begin(todo) }
            }
            // Measured *outside* the drag modifier, not between it and the
            // row. `onGeometryChange` writes state on every layout pass, and a
            // write underneath `draggable` invalidates the subtree the drag
            // session is anchored to — the lift is then cancelled by the very
            // measurement meant to size its preview.
            //
            // `onGeometryChange` rather than wrapping the row in a
            // `GeometryReader`: a wrapping reader reports no intrinsic size of
            // its own, so the row would lose the height it derives from its
            // content. This measures without taking part in layout.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                rowSize = size
            }
            // Suppresses the drag while the row is being edited, without
            // removing the modifier. A zero-distance drag gesture claims the
            // press ahead of the drag session but does nothing with it, so a
            // press inside the focused title goes to the text field for caret
            // placement and selection — the behaviour the old `if` branch was
            // protecting.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0),
                including: isEnabled ? [] : .gesture
            )
    }
}

/// The preview that travels under the cursor while a to-do is in flight.
///
/// Enough to tell which to-do is being moved when several are going in turn,
/// and the same size as the row it lifted from so the drag reads as that row
/// rising rather than as a different, smaller object replacing it.
///
/// A named view rather than an inline closure so a test can render it at a
/// known row size and measure what comes out — see `DragPreviewSizeTests`.
struct TodoDragPreview: View {
    let todo: Todo
    /// The measured row, or `nil` before the first layout pass has reported it.
    let rowSize: CGSize?

    var body: some View {
        let size = DragPreviewSize.forRow(measuring: rowSize)

        return HStack(alignment: .center, spacing: 8) {
            // The row's own checkbox rather than an SF Symbol standing in for
            // it. A `Label`'s "circle" was a circle whatever the row drew, so
            // a project and a to-do lifted as the same shape and neither
            // matched the rounded box on screen — `TodoCheckboxShape` exists so
            // surfaces cannot drift like that, and it carries the state and
            // colour across too.
            TodoCheckboxShape(state: todo.state, tint: todo.color)

            Text((try? AttributedString(markdown: todo.title)) ?? .init(todo.title))
                .lineLimit(1)
                .foregroundStyle(todo.state.isResolved ? .secondary : .primary)
                .strikethrough(todo.state == .completed)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // Vertical padding only until the row has been measured. Once the frame
        // below sets a real height, padding on top of it would make the preview
        // taller than the row it came from — the same mismatch in the other
        // direction.
        .padding(.vertical, size.height == nil ? 8 : 0)
        // Exact dimensions, not `maxWidth`/`maxHeight`. A max is only an upper
        // bound: under the unconstrained proposal a drag preview is laid out
        // with, the content keeps its own ideal size and the max never pulls it
        // out to the row's width, which is the bug this is here to fix. A `nil`
        // dimension still means "size to your own content", so an unmeasured
        // axis falls back to wrapping as before.
        //
        // Leading alignment so the title sits where it does in the row rather
        // than centring itself horizontally.
        .frame(
            width: size.width,
            height: size.height,
            alignment: .leading
        )
        // An opaque background, not `.thinMaterial`, and a rounded rectangle
        // rather than a `Capsule`.
        //
        // The material was what made the text look out of focus on iOS while
        // the same view stayed crisp on macOS: UIKit renders a SwiftUI drag
        // preview into an offscreen snapshot with no backdrop behind it, so a
        // material has nothing to blur and resolves to a soft grey wash.
        // `rowCard` is the fill an expanded row's card already uses — opaque,
        // and the system's own colour in both appearances.
        //
        // The capsule turned every preview into a lozenge with semicircular
        // ends, which reads as a pill or a token rather than as the row that
        // was picked up. `Theme.Metrics.cornerRadius` is what the app's other
        // surfaces use.
        // The shadow goes on the background shape rather than on the whole
        // preview: `.shadow` applied outside casts from every glyph as well as
        // from the card, which put a grey halo behind the title. The same
        // shadow the list's rows cast, so the lifted row is lit like the ones
        // it left behind.
        .background {
            previewShape
                .fill(Color.rowCard)
                .shadow(
                    color: .black.opacity(Theme.Metrics.rowShadowOpacity),
                    radius: Theme.Metrics.rowShadowRadius,
                    y: Theme.Metrics.rowShadowOffset
                )
        }
        // No `clipShape` around the whole preview: it would clip the shadow
        // drawn above to the card's own bounds and erase it. The content is
        // inset by the padding and truncates on its own, so there is nothing
        // to clip.
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
    }
}

private struct TodoDropTargetModifier: ViewModifier {
    let destination: ListDestination
    let store: TodoStore
    let externalTargeting: Binding<Bool>?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                // Drawn behind rather than as an overlay so it never sits over
                // the row's own text or intercepts the drop itself.
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.18 : 0))
                    .animation(Theme.Animation.quick, value: isTargeted)
            }
            // One `dropDestination`, and nothing layered over it. A second drop
            // target on the same view — even a `DropDelegate` that only wanted
            // to watch the pointer — wins the drag on macOS and this one never
            // sees it, which is what stopped a drag that crossed a list from
            // reaching the sidebar.
            //
            // Not branched between two differently-shaped modifier chains,
            // and emphatically not through `AnyView`: an erased or switched
            // view type changes this subtree's identity between updates, and
            // SwiftUI rebuilds it — taking the in-flight drag session with it.
            // That is the same hazard the note on `TodoDraggableModifier`
            // describes, and a drop target is just as vulnerable to it.
            .dropDestination(for: TodoTransfer.self) { items, _ in
                var handled = false
                for item in items where handleTransfer(item) {
                    handled = true
                }
                // The drag is over however it was handled, so the record of
                // what was being dragged goes with it — see `ActiveDrag`.
                ActiveDrag.shared.end()
                return handled
            } isTargeted: { targeted in
                isTargeted = targeted
                externalTargeting?.wrappedValue = targeted
            }
    }

    /// Apply one transfer, and say whether anything moved.
    private func handleTransfer(_ item: TodoTransfer) -> Bool {
        // The transfer carries a `uuid`, so the dragged row is a point fetch
        // rather than a scan of every to-do on screen.
        guard let todo = TodoQueries.todo(uuid: item.uuid, in: store.context) else { return false }
        return TodoDropAction.apply(destination, to: todo, store: store)
    }
}

