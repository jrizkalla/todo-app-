import Testing
import Foundation
import SwiftData
@testable import TODO

/// The shared suggestion behavior behind both the inline row editor and the
/// detail view.
@MainActor
struct TitleSuggestionModelTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Typing a date phrase surfaces the schedule/deadline pair.
    @Test func refreshSurfacesSuggestions() throws {
        let context = try makeContext()
        let todo = Todo(title: "Clean car tomorrow")
        context.insert(todo)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])

        #expect(model.suggestions.count == 2)
    }

    /// Applying a schedule chip sets the date and strips the phrase.
    @Test func applyingScheduleSetsDateAndStripsText() throws {
        let context = try makeContext()
        let todo = Todo(title: "Clean car tomorrow")
        context.insert(todo)
        let store = TodoStore(context: context)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])

        guard let schedule = model.suggestions.first(where: {
            if case .schedule = $0.kind { return true } else { return false }
        }) else {
            Issue.record("expected a schedule suggestion")
            return
        }

        let rewritten = model.apply(schedule, to: todo, allTodos: [todo], store: store)

        #expect(rewritten == "Clean car")
        #expect(todo.title == "Clean car")
        #expect(todo.assignedDate != nil)
        #expect(Calendar.current.isDateInTomorrow(todo.assignedDate!))
    }

    /// Applying a deadline chip fills the due date rather than the assigned one.
    @Test func applyingDeadlineSetsDueDate() throws {
        let context = try makeContext()
        let todo = Todo(title: "File taxes tomorrow")
        context.insert(todo)
        let store = TodoStore(context: context)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])

        guard let deadline = model.suggestions.first(where: {
            if case .deadline = $0.kind { return true } else { return false }
        }) else {
            Issue.record("expected a deadline suggestion")
            return
        }

        model.apply(deadline, to: todo, allTodos: [todo], store: store)

        #expect(todo.title == "File taxes")
        #expect(todo.dueDate != nil)
        #expect(todo.assignedDate == nil)
    }

    /// Applying a duration chip sets the duration.
    @Test func applyingDurationSetsDuration() throws {
        let context = try makeContext()
        let todo = Todo(title: "Stretch 20 minutes")
        context.insert(todo)
        let store = TodoStore(context: context)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])

        guard let duration = model.suggestions.first(where: {
            if case .duration = $0.kind { return true } else { return false }
        }) else {
            Issue.record("expected a duration suggestion")
            return
        }

        model.apply(duration, to: todo, allTodos: [todo], store: store)

        #expect(todo.title == "Stretch")
        #expect(todo.duration == 1200)
    }

    /// A todo never offers to move into itself.
    @Test func todoDoesNotSuggestItself() throws {
        let context = try makeContext()
        let project = Todo(title: "Kitchen", isProject: true)
        context.insert(project)

        let model = TitleSuggestionModel()
        model.refresh(for: "Kitchen", todo: project, allTodos: [project])

        #expect(model.suggestions.contains {
            if case .project = $0.kind { return true } else { return false }
        } == false)
    }

    /// Applying a project chip files the todo under it.
    @Test func applyingProjectMovesTodo() throws {
        let context = try makeContext()
        let project = Todo(title: "Kitchen", isProject: true)
        let todo = Todo(title: "Paint Kitchen walls")
        [project, todo].forEach(context.insert)
        let store = TodoStore(context: context)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [project, todo])

        guard let match = model.suggestions.first(where: {
            if case .project = $0.kind { return true } else { return false }
        }) else {
            Issue.record("expected a project suggestion")
            return
        }

        model.apply(match, to: todo, allTodos: [project, todo], store: store)

        #expect(todo.parent === project)
        #expect(todo.title == "Paint walls")
    }

    /// After applying, the chips reflect the rewritten title rather than going
    /// stale against the old text.
    @Test func suggestionsRefreshAfterApplying() throws {
        let context = try makeContext()
        let todo = Todo(title: "Clean car tomorrow")
        context.insert(todo)
        let store = TodoStore(context: context)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])

        guard let first = model.suggestions.first else {
            Issue.record("expected a suggestion")
            return
        }
        model.apply(first, to: todo, allTodos: [todo], store: store)

        // "tomorrow" is gone, so no date chips should remain.
        #expect(model.suggestions.isEmpty)
    }

    @Test func clearRemovesSuggestions() throws {
        let context = try makeContext()
        let todo = Todo(title: "Clean car tomorrow")
        context.insert(todo)

        let model = TitleSuggestionModel()
        model.refresh(for: todo.title, todo: todo, allTodos: [todo])
        #expect(!model.suggestions.isEmpty)

        model.clear()
        #expect(model.suggestions.isEmpty)
    }
}
