import Testing
import Foundation
import SwiftData
@testable import TODO

/// The suggestion pipeline end to end: what the model offers for a title, and
/// what accepting a chip leaves behind.
@MainActor
struct TitleSuggestionIntegrationTests {

    private func makeStore() throws -> TodoStore {
        let container = try ModelContainer.appContainer(inMemory: true)
        return TodoStore(context: ModelContext(container))
    }

    /// The rewritten title differs from what the user typed, which is what
    /// `TodoRow` relies on to tell an external edit from the echo of its own
    /// keystrokes — the distinction that decides whether the field updates.
    ///
    /// Guards the fix for the reported bug: the row used to skip the sync while
    /// its field had focus, which is the only time chips are ever on screen, so
    /// the accepted phrase stayed visible and the stale copy put it back on the
    /// next keystroke.
    @Test func acceptingAChipChangesTheStoredTitle() throws {
        let store = try makeStore()
        let typed = "Clean car today"
        let todo = store.createTodo(title: typed)
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)
        let chip = try #require(model.suggestions.first {
            if case .schedule = $0.kind { true } else { false }
        })

        let rewritten = model.apply(chip, to: todo, context: store.context, store: store)
        #expect(rewritten != typed)
        #expect(todo.title != typed)
    }

    /// The reported bug: accepting a date chip has to strip the phrase.
    @Test func acceptingAScheduleChipClearsThePhrase() throws {
        let store = try makeStore()
        let todo = store.createTodo(title: "Clean car today")
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)
        let chip = try #require(model.suggestions.first {
            if case .schedule = $0.kind { true } else { false }
        })

        let rewritten = model.apply(chip, to: todo, context: store.context, store: store)

        #expect(rewritten == "Clean car")
        #expect(todo.title == "Clean car")
        #expect(todo.assignedDate != nil)
    }

    /// The other half of the report: a project's name in a title should offer
    /// to file the to-do under it.
    @Test func projectNamesAreDetected() throws {
        let store = try makeStore()
        let project = store.createTodo(title: "Kitchen", isProject: true)
        let todo = store.createTodo(title: "Buy tiles for Kitchen")
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)

        let chip = model.suggestions.first { if case .project = $0.kind { true } else { false } }
        #expect(chip != nil, "expected a project chip for a title naming an existing project")

        if let chip {
            _ = model.apply(chip, to: todo, context: store.context, store: store)
            #expect(todo.parent?.uuid == project.uuid)
            #expect(todo.title == "Buy tiles for")
        }
    }

    /// The other half of the report: a space's name should be detected the same
    /// way a project's is.
    @Test func spaceNamesAreDetected() throws {
        let store = try makeStore()
        let space = store.createSpace(name: "Errands")
        let todo = store.createTodo(title: "Buy stamps Errands")
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)

        let chip = try #require(model.suggestions.first {
            if case .space = $0.kind { true } else { false }
        })

        _ = model.apply(chip, to: todo, context: store.context, store: store)
        #expect(todo.space?.uuid == space.uuid)
        #expect(todo.title == "Buy stamps")
    }

    /// A chip for the container the to-do already sits in would do nothing when
    /// accepted, so it is not offered.
    @Test func theCurrentSpaceIsNotSuggested() throws {
        let store = try makeStore()
        let space = store.createSpace(name: "Errands")
        let todo = store.createTodo(title: "Buy stamps Errands", space: space)
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)

        #expect(!model.suggestions.contains { if case .space = $0.kind { true } else { false } })
    }

    /// Filing into a space detaches any parent: a to-do lives in one container,
    /// and its project may sit in a different space.
    @Test func acceptingASpaceDetachesTheParent() throws {
        let store = try makeStore()
        let space = store.createSpace(name: "Errands")
        let project = store.createTodo(title: "Kitchen", isProject: true)
        let todo = store.addSubtask(to: project, title: "Buy stamps Errands")
        let model = TitleSuggestionModel()

        model.refresh(for: todo.title, todo: todo, context: store.context)
        let chip = try #require(model.suggestions.first {
            if case .space = $0.kind { true } else { false }
        })

        _ = model.apply(chip, to: todo, context: store.context, store: store)
        #expect(todo.parent == nil)
        #expect(todo.space?.uuid == space.uuid)
    }
}
