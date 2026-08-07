import Testing
import Foundation
import SwiftData
@testable import TODO

/// The export seam's pure mapping logic. EventKit writes are not exercised —
/// these cover the translation the future feature will depend on.
@MainActor
struct ExportServiceTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Markdown export renders a checklist with completion state.
    @Test func markdownRendersCheckboxes() throws {
        let context = try makeContext()
        let open = Todo(title: "Open item")
        let done = Todo(title: "Done item")
        [open, done].forEach(context.insert)
        done.setState(.completed)

        let output = ExportService.markdown(for: [open, done])

        #expect(output.contains("- [ ] Open item"))
        #expect(output.contains("- [x] Done item"))
    }

    /// Cancelled work is resolved, so it exports as checked too.
    @Test func markdownTreatsCancelledAsResolved() throws {
        let context = try makeContext()
        let cancelled = Todo(title: "Dropped")
        context.insert(cancelled)
        cancelled.setState(.cancelled)

        #expect(ExportService.markdown(for: [cancelled]).contains("- [x] Dropped"))
    }

    /// Subtasks nest by indentation.
    @Test func markdownNestsSubtasks() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        [parent, child].forEach(context.insert)
        parent.addSubtask(child)

        let output = ExportService.markdown(for: [parent])

        #expect(output.contains("- [ ] Parent"))
        #expect(output.contains("  - [ ] Child"))
    }

    /// A deadline is annotated inline.
    @Test func markdownIncludesDueDate() throws {
        let context = try makeContext()
        let todo = Todo(title: "Taxes", dueDate: Date())
        context.insert(todo)

        #expect(ExportService.markdown(for: [todo]).contains("(due "))
    }

    /// Markdown marks are stripped for destinations that show plain text.
    @Test func plainTitleStripsMarkdown() throws {
        let context = try makeContext()
        let todo = Todo(title: "Call **Dana** about the *invoice*")
        context.insert(todo)

        #expect(todo.plainTitle == "Call Dana about the invoice")
    }

    /// A title with no markup passes through unchanged.
    @Test func plainTitleLeavesPlainTextAlone() throws {
        let context = try makeContext()
        let todo = Todo(title: "Buy milk")
        context.insert(todo)

        #expect(todo.plainTitle == "Buy milk")
    }
}
