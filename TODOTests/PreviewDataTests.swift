import Testing
import Foundation
import SwiftData
@testable import TODO

/// The preview fixture itself.
///
/// Previews fail in the canvas with unhelpful errors, so the seeded data is
/// checked here: if a lookup stops matching after a rename, this fails in CI
/// rather than silently leaving a blank canvas.
@MainActor
struct PreviewDataTests {

    @Test func containerSeedsSuccessfully() {
        let todos = (try? PreviewData.context.fetch(FetchDescriptor<Todo>())) ?? []
        let spaces = (try? PreviewData.context.fetch(FetchDescriptor<Space>())) ?? []

        #expect(!todos.isEmpty)
        #expect(spaces.count == 2)
    }

    /// Each named lookup must find its own item, not fall through to the
    /// `all[0]` fallback.
    @Test func namedLookupsResolve() {
        #expect(PreviewData.project.title == "Q3 Launch")
        #expect(PreviewData.project.isProject)
        #expect(PreviewData.longTitled.title.hasPrefix("Draft the quarterly"))
        #expect(PreviewData.imported.importedFromReminders)
        #expect(PreviewData.space.name == "Work")
    }

    /// The fixture has to cover the states the previews are meant to show, or
    /// the canvas looks fine while exercising nothing.
    @Test func seedCoversTheInterestingCases() {
        let todos = (try? PreviewData.context.fetch(FetchDescriptor<Todo>())) ?? []

        #expect(todos.contains { $0.state == .started }, "no started to-do")
        #expect(todos.contains { $0.state == .completed }, "no completed to-do")
        #expect(todos.contains { $0.isOverdue }, "no overdue to-do")
        #expect(todos.contains { $0.assignedHasTime }, "no timed to-do for the calendar grid")
        #expect(todos.contains { !$0.subtaskList.isEmpty }, "no parent with subtasks")
        #expect(todos.contains { $0.isNew }, "no unviewed to-do for the yellow dot")
        #expect(todos.contains { !$0.reminderList.isEmpty }, "no to-do with a reminder")
        #expect(todos.contains { $0.bucket == .inbox }, "nothing in the Inbox")
    }

    /// Colors have to reach the seeded items, since several previews exist to
    /// show them.
    @Test func seedAppliesColors() {
        #expect(PreviewData.space.colorHex == "#0A84FF")
        #expect(PreviewData.project.colorHex != nil)
        #expect(PreviewData.project.resolvedColorHex == PreviewData.project.colorHex)
    }

    /// Sample pending reminders back the import previews, which cannot reach
    /// EventKit from the canvas.
    @Test func pendingRemindersAreAvailable() {
        #expect(PreviewData.pendingReminders.count == 2)
        #expect(PreviewData.pendingReminders.contains { $0.dueDate != nil })
    }

    /// The fixture must never touch the real store.
    @Test func fixtureIsInMemoryOnly() {
        let url = PreviewData.container.configurations.first?.url
        // An in-memory configuration has no on-disk store to write to.
        #expect(url == nil || url?.path.contains("/dev/null") == true)
    }
}
