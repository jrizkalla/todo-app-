import Testing
import Foundation
import SwiftData
import SwiftUI
@testable import TODO

/// The "new / unviewed" dot: when a to-do earns one and when it loses it.
@MainActor
struct NewTrackingTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    // MARK: Baseline

    /// A to-do the user typed themselves is not new to them.
    @Test func userCreatedTodoIsNotNew() throws {
        let context = try makeContext()
        let todo = Todo(title: "Typed by hand")
        context.insert(todo)

        #expect(todo.isNew == false)
    }

    /// Something arriving from outside — an import — is new until seen.
    @Test func markAsNewSetsFlag() throws {
        let context = try makeContext()
        let todo = Todo(title: "Imported")
        context.insert(todo)

        todo.markAsNew()

        #expect(todo.isNew)
        #expect(todo.lastViewedPlacement == nil)
    }

    /// Viewing clears the dot and records where it was seen.
    @Test func markAsViewedClearsFlag() throws {
        let context = try makeContext()
        let todo = Todo(title: "Imported")
        context.insert(todo)
        todo.markAsNew()

        todo.markAsViewed()

        #expect(todo.isNew == false)
        #expect(todo.lastViewedPlacement == todo.placementFingerprint)
    }

    // MARK: Placement changes

    /// Moving to another space makes it new again, since it now appears
    /// somewhere the user has not looked.
    @Test func movingToNewSpaceMakesItNew() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let todo = Todo(title: "Task")
        context.insert(space)
        context.insert(todo)
        todo.markAsViewed()
        #expect(todo.isNew == false)

        todo.move(toSpace: space)

        #expect(todo.isNew)
    }

    /// Filing under a project counts the same way.
    @Test func movingToProjectMakesItNew() throws {
        let context = try makeContext()
        let project = Todo(title: "Project", isProject: true)
        let todo = Todo(title: "Task")
        [project, todo].forEach(context.insert)
        todo.markAsViewed()

        todo.move(toParent: project)

        #expect(todo.isNew)
    }

    /// Newly scheduling a to-do surfaces it in Today or This Week, so it is new
    /// there.
    @Test func schedulingMakesItNew() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = Todo(title: "Task")
        context.insert(todo)
        todo.markAsViewed()

        store.update(todo) { $0.assignedDate = Date() }

        #expect(todo.isNew)
    }

    /// Re-viewing after a move clears the dot again.
    @Test func viewingAfterMoveClearsFlag() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        let todo = Todo(title: "Task")
        context.insert(space)
        context.insert(todo)

        todo.markAsViewed()
        todo.move(toSpace: space)
        #expect(todo.isNew)

        todo.markAsViewed()
        #expect(todo.isNew == false)
    }

    /// An edit that does not move the to-do leaves the dot alone — renaming
    /// something should not make it look new.
    @Test func editingTitleDoesNotMakeItNew() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let todo = Todo(title: "Task")
        context.insert(todo)
        todo.markAsViewed()

        store.update(todo) { $0.title = "Renamed task" }

        #expect(todo.isNew == false)
    }

    /// Changing only the time of day is not a move, so no new dot.
    @Test func changingTimeWithinSameDayDoesNotMakeItNew() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let day = Calendar.current.startOfDay(for: Date())
        let todo = Todo(title: "Meeting", assignedDate: day)
        context.insert(todo)
        todo.markAsViewed()

        store.update(todo) {
            $0.assignedDate = day.addingTimeInterval(3 * 3600)
            $0.assignedHasTime = true
        }

        #expect(todo.isNew == false, "same day, so it has not moved lists")
    }

    /// Moving to a different day does re-flag it.
    @Test func reschedulingToAnotherDayMakesItNew() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let today = Calendar.current.startOfDay(for: Date())
        let todo = Todo(title: "Task", assignedDate: today)
        context.insert(todo)
        todo.markAsViewed()

        store.update(todo) {
            $0.assignedDate = Calendar.current.date(byAdding: .day, value: 3, to: today)
        }

        #expect(todo.isNew)
    }

    // MARK: Bulk viewing

    /// Visiting a list clears every dot it shows, in one save.
    @Test func markingListAsViewedClearsAll() throws {
        let context = try makeContext()
        let store = TodoStore(context: context)
        let a = Todo(title: "A")
        let b = Todo(title: "B")
        [a, b].forEach(context.insert)
        a.markAsNew()
        b.markAsNew()

        store.markAsViewed([a, b])

        #expect(a.isNew == false)
        #expect(b.isNew == false)
    }

    /// A never-viewed to-do stays new through a placement refresh.
    @Test func neverViewedStaysNew() throws {
        let context = try makeContext()
        let todo = Todo(title: "Imported")
        context.insert(todo)
        todo.markAsNew()

        todo.refreshNewFlagAfterPlacementChange()

        #expect(todo.isNew)
    }
}

/// Color resolution across spaces and projects.
@MainActor
struct ColorResolutionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// With nothing set, a to-do has no color and falls back to the accent.
    @Test func plainTodoHasNoColor() throws {
        let context = try makeContext()
        let todo = Todo(title: "Task")
        context.insert(todo)

        #expect(todo.resolvedColorHex == nil)
    }

    /// A to-do in a space takes that space's color.
    @Test func todoInheritsSpaceColor() throws {
        let context = try makeContext()
        let space = Space(name: "Work", colorHex: "#0A84FF")
        let todo = Todo(title: "Task")
        context.insert(space)
        context.insert(todo)

        todo.move(toSpace: space)

        #expect(todo.resolvedColorHex == "#0A84FF")
    }

    /// A project's own color wins over its space's.
    @Test func projectColorOverridesSpace() throws {
        let context = try makeContext()
        let space = Space(name: "Work", colorHex: "#0A84FF")
        let project = Todo(title: "Project", isProject: true)
        context.insert(space)
        context.insert(project)

        project.move(toSpace: space)
        project.colorHex = "#FF453A"

        #expect(project.resolvedColorHex == "#FF453A")
    }

    /// A project with no color of its own falls back to its space.
    @Test func projectWithoutColorUsesSpace() throws {
        let context = try makeContext()
        let space = Space(name: "Work", colorHex: "#32D74B")
        let project = Todo(title: "Project", isProject: true)
        context.insert(space)
        context.insert(project)

        project.move(toSpace: space)

        #expect(project.resolvedColorHex == "#32D74B")
    }

    /// A child of a colored project takes the project's color, not the space's.
    @Test func childTakesProjectColorOverSpace() throws {
        let context = try makeContext()
        let space = Space(name: "Work", colorHex: "#0A84FF")
        let project = Todo(title: "Project", isProject: true)
        let child = Todo(title: "Child")
        context.insert(space)
        [project, child].forEach(context.insert)

        project.move(toSpace: space)
        project.colorHex = "#BF5AF2"
        project.addSubtask(child)

        #expect(child.resolvedColorHex == "#BF5AF2")
    }

    /// Hex strings parse into the expected color channels.
    @Test func hexParsingProducesExpectedChannels() {
        let color = Color(hex: "#FF0000")
        #expect(color == Color(red: 1, green: 0, blue: 0))
    }

    /// Malformed hex falls back to gray rather than crashing.
    @Test func malformedHexFallsBackToGray() {
        #expect(Color(hex: "nonsense") == Color.gray)
        #expect(Color(hex: "#12") == Color.gray)
    }
}
