import Testing
import Foundation
import SwiftData
@testable import TODO

/// The Logbook's contents, which used to drop anything nested in a project.
@MainActor
struct LogbookTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// The regression: a completed subtask lives inside a project, so filtering
    /// to top-level items hid it from the history entirely.
    @Test func completedSubtasksAppear() throws {
        let context = try makeContext()
        let project = Todo(title: "Q3 Launch", isProject: true)
        let child = Todo(title: "Draft notes")
        [project, child].forEach(context.insert)
        project.addSubtask(child)
        child.setState(.completed)

        let logbook = TodoQueries.logbook([project, child])

        #expect(logbook.contains { $0.title == "Draft notes" })
    }

    /// Top-level finished work still shows.
    @Test func completedTopLevelTodosAppear() throws {
        let context = try makeContext()
        let todo = Todo(title: "Ship beta")
        context.insert(todo)
        todo.setState(.completed)

        #expect(TodoQueries.logbook([todo]).map(\.title) == ["Ship beta"])
    }

    /// Cancelled counts as resolved, so it belongs in the history too.
    @Test func cancelledTodosAppear() throws {
        let context = try makeContext()
        let todo = Todo(title: "Dropped")
        context.insert(todo)
        todo.setState(.cancelled)

        #expect(TodoQueries.logbook([todo]).map(\.title) == ["Dropped"])
    }

    /// Unfinished work stays out.
    @Test func openTodosAreExcluded() throws {
        let context = try makeContext()
        let open = Todo(title: "Still going")
        let done = Todo(title: "Finished")
        [open, done].forEach(context.insert)
        done.setState(.completed)

        #expect(TodoQueries.logbook([open, done]).map(\.title) == ["Finished"])
    }

    /// A finished project is finished work, so it belongs in the history.
    ///
    /// The sidebar drops a project once it resolves and points here, so
    /// excluding projects from the Logbook made a completed one unreachable.
    @Test func completedProjectsAppear() throws {
        let context = try makeContext()
        let project = Todo(title: "Old project", isProject: true)
        context.insert(project)
        project.setState(.completed)

        #expect(TodoQueries.logbook([project]).map(\.title) == ["Old project"])
    }

    /// An unfinished project is still a place to put work, not history.
    @Test func openProjectsAreExcluded() throws {
        let context = try makeContext()
        let project = Todo(title: "Live project", isProject: true)
        context.insert(project)

        #expect(TodoQueries.logbook([project]).isEmpty)
    }

    /// A project and the work finished inside it both show, newest first.
    @Test func completedProjectAppearsAlongsideItsSubtasks() throws {
        let context = try makeContext()
        let project = Todo(title: "Q3 Launch", isProject: true)
        let child = Todo(title: "Draft notes")
        [project, child].forEach(context.insert)
        project.addSubtask(child)

        child.setState(.completed)
        child.resolvedAt = Date().addingTimeInterval(-3600)
        project.setState(.completed)
        project.resolvedAt = Date()

        #expect(TodoQueries.logbook([project, child]).map(\.title) == ["Q3 Launch", "Draft notes"])
    }

    /// Newest first, so the most recent work is at the top.
    @Test func sortedByMostRecentlyResolved() throws {
        let context = try makeContext()
        let older = Todo(title: "Older")
        let newer = Todo(title: "Newer")
        [older, newer].forEach(context.insert)

        older.setState(.completed)
        older.resolvedAt = Date().addingTimeInterval(-3600)
        newer.setState(.completed)
        newer.resolvedAt = Date()

        #expect(TodoQueries.logbook([older, newer]).map(\.title) == ["Newer", "Older"])
    }
}

/// Selection semantics for Reminders lists and calendars.
///
/// `nil` means "never chosen" and resolves to the system default; an empty
/// array is a deliberate "none". Conflating the two is what made the app pull
/// in every calendar the user had.
@MainActor
struct SourceSelectionTests {

    private func makeSettings() -> AppSettings {
        let suite = "test-\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func unsetSelectionsStartNil() {
        let settings = makeSettings()

        #expect(settings.importReminderLists == nil)
        #expect(settings.visibleCalendars == nil)
    }

    /// An explicit empty array must survive a round trip, not read back as nil,
    /// or "show nothing" would silently become "show the default".
    @Test func emptySelectionIsDistinctFromUnset() {
        let settings = makeSettings()

        settings.visibleCalendars = []
        #expect(settings.visibleCalendars == [])
        #expect(settings.visibleCalendars != nil)

        settings.importReminderLists = []
        #expect(settings.importReminderLists == [])
    }

    @Test func selectionsRoundTrip() {
        let settings = makeSettings()

        settings.visibleCalendars = ["a", "b"]
        #expect(settings.visibleCalendars == ["a", "b"])

        settings.importReminderLists = ["x"]
        #expect(settings.importReminderLists == ["x"])
    }

    /// Assigning nil clears the choice, returning to the default.
    @Test func assigningNilResetsToUnset() {
        let settings = makeSettings()

        settings.visibleCalendars = ["a"]
        settings.visibleCalendars = nil

        #expect(settings.visibleCalendars == nil)
    }

    // MARK: Summary text

    @Test func summaryNamesTheDefaultWhenUnset() {
        #expect(
            SourceSelectionView.summary(selection: nil, sources: [], defaultIdentifier: nil)
                == "Default"
        )
    }

    @Test func summaryReportsNoneForEmpty() {
        #expect(
            SourceSelectionView.summary(selection: [], sources: [], defaultIdentifier: nil)
                == "None"
        )
    }
}
