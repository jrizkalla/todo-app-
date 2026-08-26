import Testing
import Foundation
import SwiftData
@testable import TODO

/// Instance generation against a real store: the properties that make a
/// recurring to-do behave like one to-do rather than a pile of them.
@MainActor
struct RecurrenceEngineTests {

    private func makeStore() throws -> TodoStore {
        UndoStack.shared.reset()
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    private func engine(_ store: TodoStore) -> RecurrenceEngine {
        RecurrenceEngine(context: store.context)
    }

    private func allTodos(_ store: TodoStore) -> [Todo] {
        (try? store.context.fetch(FetchDescriptor<Todo>())) ?? []
    }

    /// A daily rule starting today, which is the simplest thing that generates.
    private func dailyRule(status: RecurrenceStatus = .active) -> RecurrenceRule {
        var rule = RecurrenceRule(mode: .onSchedule, frequency: .daily, interval: 1)
        rule.status = status
        return rule
    }

    // MARK: Becoming a template

    @Test func settingARuleMakesATodoATemplateAndGeneratesAnInstance() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Water the plants")

        store.setRecurrence(dailyRule(), on: todo)

        #expect(todo.isRecurrenceTemplate)
        #expect(todo.recurrenceInstanceList.count == 1)

        let instance = try #require(todo.currentRecurrenceInstance)
        #expect(instance.title == "Water the plants")
        #expect(instance.recurrenceTemplate?.uuid == todo.uuid)
        // The instance is an ordinary to-do, not a second template.
        #expect(!instance.isRecurrenceTemplate)
    }

    /// The rule the whole feature rests on: the template is never itself a row
    /// in a dated list — its instance is.
    @Test func anActiveTemplateIsNotInTheDatedLists() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        let today = TodoQueries.today(allTodos(store))
        #expect(!today.contains { $0.uuid == todo.uuid })
        // But the occurrence it generated is there.
        #expect(today.contains { $0.recurrenceTemplate?.uuid == todo.uuid })
    }

    /// The spec's requirement for a paused series: it shows in Anytime, where a
    /// user can find it and start it again.
    @Test func aPausedTemplateSurfacesInAnytime() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Deep clean")
        store.setRecurrence(dailyRule(), on: todo)
        store.setRecurrenceStatus(.paused, on: todo)

        let anytime = TodoQueries.anytime(allTodos(store))
        #expect(anytime.contains { $0.uuid == todo.uuid })
        #expect(todo.isDormantRecurrenceTemplate)
    }

    /// An *active* one must not, or the same recurring task appears twice.
    @Test func anActiveTemplateDoesNotSurfaceInAnytime() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        let anytime = TodoQueries.anytime(allTodos(store))
        #expect(!anytime.contains { $0.uuid == todo.uuid })
    }

    // MARK: Generation is idempotent

    /// The property that lets the engine run on every launch and every
    /// completion without being scheduled or debounced.
    @Test func runningTheEngineTwiceProducesNoDuplicates() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        let before = todo.recurrenceInstanceList.count
        engine(store).generateDueInstances()
        engine(store).generateDueInstances()

        #expect(todo.recurrenceInstanceList.count == before)
    }

    // MARK: Completion drives the next one

    @Test func completingAnInstanceCreatesTheNextOne() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Water the plants")
        var rule = RecurrenceRule(mode: .afterCompletion, frequency: .daily, interval: 3)
        rule.status = .active
        store.setRecurrence(rule, on: todo)

        let first = try #require(todo.currentRecurrenceInstance)
        #expect(store.setState(first, to: .completed) == .applied)

        // The completed one is still there — it is history — and a fresh open
        // occurrence has joined it.
        let open = todo.recurrenceInstanceList.filter { !$0.state.isResolved }
        #expect(open.count == 1)
        #expect(open.first?.uuid != first.uuid)

        // And it lands three days out, measured from the completion.
        let next = try #require(open.first?.assignedDate)
        let daysOut = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: Date()), to: next
        ).day
        #expect(daysOut == 3)
    }

    /// A completion-gated series holds exactly one open occurrence at a time.
    @Test func aCompletionGatedSeriesHasOneOpenInstance() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Pay rent")
        var rule = RecurrenceRule(
            mode: .afterCompletionOnSchedule, frequency: .daily, interval: 1
        )
        rule.status = .active
        store.setRecurrence(rule, on: todo)

        // Even asked repeatedly, it must not run ahead.
        engine(store).generateDueInstances()
        engine(store).generateDueInstances()

        let open = todo.recurrenceInstanceList.filter { !$0.state.isResolved }
        #expect(open.count == 1)
    }

    /// Reopening must not leave the series with two live occurrences — the bug
    /// a naive "generate on completion" produces the moment someone un-ticks.
    @Test func reopeningAnInstanceTakesBackItsSuccessor() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Water the plants")
        var rule = RecurrenceRule(mode: .afterCompletion, frequency: .daily, interval: 2)
        rule.status = .active
        store.setRecurrence(rule, on: todo)

        let first = try #require(todo.currentRecurrenceInstance)
        _ = store.setState(first, to: .completed)
        #expect(todo.recurrenceInstanceList.filter { !$0.state.isResolved }.count == 1)

        _ = store.setState(first, to: .open)

        let open = todo.recurrenceInstanceList.filter { !$0.state.isResolved }
        #expect(open.count == 1)
        #expect(open.first?.uuid == first.uuid)
    }

    // MARK: Pausing and cancelling

    @Test func pausingRemovesThePendingInstance() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)
        #expect(todo.currentRecurrenceInstance != nil)

        store.setRecurrenceStatus(.paused, on: todo)
        #expect(todo.currentRecurrenceInstance == nil)
    }

    @Test func resumingGeneratesAgain() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)
        store.setRecurrenceStatus(.paused, on: todo)
        store.setRecurrenceStatus(.active, on: todo)

        #expect(todo.currentRecurrenceInstance != nil)
        #expect(todo.recurrenceRule?.status == .active)
    }

    /// Cancelling ends the series but must not destroy the work already done —
    /// a completed occurrence is part of the user's history.
    @Test func cancellingKeepsCompletedInstances() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        let first = try #require(todo.currentRecurrenceInstance)
        _ = store.setState(first, to: .completed)

        store.setRecurrenceStatus(.cancelled, on: todo)

        #expect(todo.recurrenceInstanceList.contains { $0.uuid == first.uuid })
        #expect(first.state == .completed)
        #expect(todo.recurrenceRule?.status == .cancelled)
    }

    /// A pending occurrence the user has *edited* is their work, not a
    /// placeholder, so pausing leaves it alone.
    @Test func pausingKeepsAnEditedInstance() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        let instance = try #require(todo.currentRecurrenceInstance)
        instance.title = "Standup — bring the slides"
        store.save()

        store.setRecurrenceStatus(.paused, on: todo)
        #expect(todo.recurrenceInstanceList.contains { $0.uuid == instance.uuid })
    }

    // MARK: Stopping

    /// Stopping repetition frees the occurrences rather than deleting them.
    @Test func stoppingRepetitionKeepsInstancesAsPlainTodos() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)
        let instance = try #require(todo.currentRecurrenceInstance)

        store.setRecurrence(nil, on: todo)

        #expect(!todo.isRecurrenceTemplate)
        #expect(!instance.isRecurrenceInstance)
        #expect(instance.recurrenceTemplate == nil)
        // Still a real to-do the user can do.
        #expect(allTodos(store).contains { $0.uuid == instance.uuid })
    }

    // MARK: Skipping

    @Test func skippingAdvancesTheSeriesWithoutCompleting() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Water the plants")
        var rule = RecurrenceRule(mode: .afterCompletion, frequency: .daily, interval: 2)
        rule.status = .active
        store.setRecurrence(rule, on: todo)

        let first = try #require(todo.currentRecurrenceInstance)
        store.skipRecurrenceInstance(first)

        // The skipped one is gone rather than recorded as done, and a fresh one
        // stands in its place.
        #expect(!todo.recurrenceInstanceList.contains { $0.uuid == first.uuid })
        #expect(todo.currentRecurrenceInstance != nil)
        #expect(!todo.recurrenceInstanceList.contains { $0.state == .completed })
    }

    // MARK: Content

    /// Each occurrence gets its own checklist, starting unticked: last week's
    /// progress says nothing about this week's.
    @Test func anInstanceCopiesTheTemplatesSubtasks() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Weekly review")
        store.addSubtask(to: todo, title: "Clear inbox")
        store.addSubtask(to: todo, title: "Plan the week")

        store.setRecurrence(dailyRule(), on: todo)

        let instance = try #require(todo.currentRecurrenceInstance)
        #expect(instance.orderedSubtasks.map(\.title) == ["Clear inbox", "Plan the week"])
        #expect(instance.orderedSubtasks.allSatisfy { $0.state == .open })
    }

    /// A generated to-do arrives without the user's doing, so it carries the
    /// same "new" marker an imported reminder does.
    @Test func aGeneratedInstanceIsMarkedNew() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)

        #expect(todo.currentRecurrenceInstance?.isNew == true)
    }

    // MARK: Undo

    @Test func undoRemovesARecurrenceRule() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)
        #expect(todo.isRecurrenceTemplate)

        UndoStack.shared.undo(in: store.context)
        #expect(!todo.isRecurrenceTemplate)
    }

    @Test func undoRestoresAPausedSeriesToActive() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Standup")
        store.setRecurrence(dailyRule(), on: todo)
        store.setRecurrenceStatus(.paused, on: todo)
        #expect(todo.recurrenceRule?.status == .paused)

        UndoStack.shared.undo(in: store.context)
        #expect(todo.recurrenceRule?.status == .active)
    }

    // MARK: Catch-up

    /// An app left closed for a month must not greet the user with a stack of
    /// identical overdue rows.
    @Test func aLongGapCollapsesToOneCurrentInstance() throws {
        let store = try makeStore()
        let calendar = Calendar.current
        let todo = store.createTodo(title: "Standup")

        // A daily series whose next date is three weeks in the past.
        todo.recurrenceRule = dailyRule()
        todo.recurrenceNextDate = calendar.date(byAdding: .day, value: -21, to: Date())
        store.save()

        engine(store).generateInstances(for: todo)

        let open = todo.recurrenceInstanceList.filter { !$0.state.isResolved }
        #expect(open.count == 1)
        // And what survives is current, not three weeks stale.
        let date = try #require(open.first?.assignedDate)
        #expect(date >= calendar.startOfDay(for: Date()))
    }

    // MARK: Round trip

    /// Recurrence has to survive an export and re-import, or a backup silently
    /// turns every recurring to-do into a one-off.
    @Test func recurrenceSurvivesAnArchiveRoundTrip() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Pay rent")
        let rule = RecurrenceRule(
            mode: .afterCompletionOnSchedule,
            frequency: .monthly,
            interval: 1,
            dayOfMonth: 1,
            timeOfDayMinutes: 9 * 60,
            status: .active
        )
        store.setRecurrence(rule, on: todo)

        let data = try DatabaseExporter(context: store.context).makeArchive()

        let container = try ModelContainer.appContainer(inMemory: true)
        let destination = ModelContext(container)
        _ = try DatabaseImporter(context: destination).importArchive(data)

        let imported = (try destination.fetch(FetchDescriptor<Todo>()))
        let template = try #require(imported.first { $0.isRecurrenceTemplate })
        #expect(template.recurrenceRule == rule.normalized())

        // And the instance still points back at it.
        let instance = try #require(imported.first { $0.isRecurrenceInstance })
        #expect(instance.recurrenceTemplate?.uuid == template.uuid)
    }
}
