import Testing
import Foundation
import SwiftData
@testable import TODO

/// Which slice of the day the summary's schedule card draws.
///
/// The card shows the next couple of hours, but a day with a gap in it would
/// leave that window empty while there is still work to come. These cover the
/// jump forward, the cases that must *not* jump, and the emptiness the summary
/// keys its "All clear" card off.
@MainActor
struct SummaryWindowTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    private var calendar: Calendar { Calendar.current }

    /// A time today, so the fixtures land on the day the card queries.
    private func today(at hour: Int, minute: Int = 0) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: calendar.startOfDay(for: Date())
        )!
    }

    /// A timed to-do at a given hour today.
    private func timed(_ title: String, at hour: Int, minute: Int = 0, context: ModelContext) -> Todo {
        let todo = Todo(title: title, assignedDate: today(at: hour, minute: minute))
        todo.assignedHasTime = true
        context.insert(todo)
        return todo
    }

    private func card(todos: [Todo], events: [CalendarEvent] = []) -> InlineCalendarCard {
        InlineCalendarCard(
            todos: todos,
            events: events,
            calendar: calendar,
            defaultDuration: 30 * 60
        )
    }

    // MARK: Live window

    /// Something inside the next two hours keeps the window anchored to now.
    @Test func windowStaysLiveWhenSomethingIsComingUp() throws {
        let context = try makeContext()
        let soon = timed("Standup", at: 10, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [soon]), now: today(at: 9))

        #expect(window.isAhead == false)
        #expect(window.blocks.map(\.title) == ["Standup"])
    }

    /// The live window reaches back far enough to keep something that started a
    /// few minutes ago on screen, rather than dropping it the moment it begins.
    @Test func windowKeepsWorkThatJustStarted() throws {
        let context = try makeContext()
        let running = timed("Interview", at: 9, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [running]), now: today(at: 9, minute: 20))

        #expect(window.isAhead == false)
        #expect(window.blocks.map(\.title) == ["Interview"])
    }

    // MARK: Jumping ahead

    /// An empty next-two-hours skips forward to the first window with work in
    /// it, rather than drawing two hours of nothing.
    @Test func windowJumpsToTheNextScheduledWork() throws {
        let context = try makeContext()
        let later = timed("Dentist", at: 15, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [later]), now: today(at: 9))

        #expect(window.isAhead)
        #expect(window.blocks.map(\.title) == ["Dentist"])
    }

    /// The jumped window starts on the hour containing the next block, so the
    /// hour gutter stays whole hours and the block sits near the top.
    @Test func jumpedWindowStartsOnTheHour() throws {
        let context = try makeContext()
        let later = timed("Dentist", at: 15, minute: 40, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [later]), now: today(at: 9))

        #expect(window.start == today(at: 15))
    }

    /// A jump pulls in everything sharing that window, not just the one block
    /// that triggered it.
    @Test func jumpedWindowKeepsItsNeighbours() throws {
        let context = try makeContext()
        let first = timed("Dentist", at: 15, context: context)
        let second = timed("Pharmacy", at: 16, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [first, second]), now: today(at: 9))

        #expect(Set(window.blocks.map(\.title)) == ["Dentist", "Pharmacy"])
    }

    /// A jumped window is sized from its own start, not from the clock. Sizing
    /// it against `now` grew the grid an hour taller for every empty hour it
    /// skipped, which is how a morning check-in produced a card tall enough to
    /// scroll past.
    ///
    /// Both fixtures are far enough out to actually jump — a block still inside
    /// the live window keeps the card anchored to now and is sized from there,
    /// which is a different case (see `windowStaysLiveWhenSomethingIsComingUp`).
    @Test func jumpedWindowDoesNotGrowWithTheGap() throws {
        let context = try makeContext()
        let near = timed("Dentist", at: 14, context: context)
        let far = timed("Dentist", at: 20, context: context)

        let shortGap = InlineCalendarCard.Window(card: card(todos: [near]), now: today(at: 9))
        let longGap = InlineCalendarCard.Window(card: card(todos: [far]), now: today(at: 9))

        #expect(shortGap.isAhead && longGap.isAhead)
        #expect(shortGap.hours.count == longGap.hours.count)
    }

    // MARK: Nothing left

    /// Work that already finished is not "next up" — an afternoon with nothing
    /// left in it is empty, however full the morning was.
    @Test func finishedWorkDoesNotBringTheWindowBack() throws {
        let context = try makeContext()
        let past = timed("Standup", at: 9, context: context)

        let window = InlineCalendarCard.Window(card: card(todos: [past]), now: today(at: 17))

        #expect(window.blocks.isEmpty)
    }

    /// An empty day leaves the card with nothing, which is what the summary
    /// replaces with "All clear".
    @Test func emptyDayHasNoContent() throws {
        #expect(card(todos: []).hasContent(now: today(at: 9)) == false)
    }

    /// The card reports content when its window found something, including a
    /// window it had to jump to.
    @Test func hasContentFollowsTheJumpedWindow() throws {
        let context = try makeContext()
        let later = timed("Dentist", at: 15, context: context)

        #expect(card(todos: [later]).hasContent(now: today(at: 9)))
    }

    /// Untimed work never reaches the grid, so a day holding only untimed items
    /// leaves the schedule card empty — it belongs to the Any Time card.
    @Test func untimedWorkLeavesTheScheduleEmpty() throws {
        let context = try makeContext()
        let untimed = Todo(title: "Water the plants", assignedDate: today(at: 0))
        context.insert(untimed)

        #expect(card(todos: [untimed]).hasContent(now: today(at: 9)) == false)
    }

    // MARK: Any Time emptiness

    /// The Any Time card's own emptiness check, which the summary uses to decide
    /// whether to place it. Timed work does not count toward it.
    @Test func anyTimeContentIgnoresTimedWork() throws {
        let context = try makeContext()
        let timedOnly = timed("Standup", at: 10, context: context)

        #expect(TodoListCard.hasContent(todos: [timedOnly]) == false)
    }

    @Test func anyTimeContentFindsUntimedWork() throws {
        let context = try makeContext()
        let untimed = Todo(title: "Water the plants", assignedDate: today(at: 0))
        context.insert(untimed)

        #expect(TodoListCard.hasContent(todos: [untimed]))
    }
}
