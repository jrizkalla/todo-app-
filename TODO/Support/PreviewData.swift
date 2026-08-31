#if DEBUG
import Foundation
import os
import SwiftUI
import SwiftData

/// Sample data for SwiftUI previews.
///
/// Every preview shares one in-memory container so the canvas shows realistic
/// content — colored spaces, a project with subtasks, overdue and timed work —
/// rather than empty lists. Debug-only, and never touches the real store.
@MainActor
enum PreviewData {

    /// A container seeded once and reused by every preview in the session.
    ///
    /// Built eagerly as a `let`: a preview that trapped here would fail with an
    /// unhelpful crash, so it is better to fail loudly at first use.
    static let container: ModelContainer = {
        let container = try! ModelContainer.appContainer(inMemory: true)
        seed(into: container.mainContext)
        return container
    }()

    static var context: ModelContext { container.mainContext }

    private static var calendar: Calendar { .current }
    private static var today: Date { calendar.startOfDay(for: Date()) }

    private static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private static func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
    }

    // MARK: Seeding

    /// Put the preview fixture into a real store, for UI verification.
    ///
    /// Runs with `-seedSampleData` and only in debug builds. Skipped when the
    /// store already holds something, so re-launching does not stack duplicate
    /// copies of every sample to-do on top of each other.
    static func seedIfEmpty(into context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Todo>())) ?? 0
        guard existing == 0 else {
            AppLog.data.info("Sample seeder: store already populated")
            return
        }

        seed(into: context)
        AppLog.data.info("Sample seeder: added sample spaces, projects, and to-dos")
    }

    private static func seed(into context: ModelContext) {
        let work = Space(name: "Work", symbolName: "briefcase", colorHex: "#0A84FF", sortIndex: 0)
        let home = Space(name: "Home", symbolName: "house", colorHex: "#32D74B", sortIndex: 1)
        context.insert(work)
        context.insert(home)

        // A project with mixed-state subtasks, to exercise the checklist badge
        // and the nested-row layout.
        let project = Todo(title: "Q3 Launch", isProject: true)
        context.insert(project)
        project.move(toSpace: work)
        project.colorHex = "#BF5AF2"

        // Dated so the project's own calendar has blocks to lay out, which is
        // the whole point of scoping a grid to a container.
        let draft = Todo(title: "Draft the **release notes**", assignedDate: time(10))
        draft.assignedHasTime = true
        draft.duration = 3600
        let brief = Todo(title: "Brief the support team")
        context.insert(draft)
        context.insert(brief)
        project.addSubtask(draft)
        project.addSubtask(brief)
        brief.setState(.completed)

        // A grandchild, so the project calendar's walk down the whole subtask
        // tree — rather than one level — is visible in the running app.
        let slides = Todo(title: "Prepare the launch slides", assignedDate: time(13))
        slides.assignedHasTime = true
        slides.duration = 5400
        context.insert(slides)
        draft.addSubtask(slides)

        // Today: a spread of states, dates, and metadata.
        let review = Todo(title: "Review `parseDate()` pull request", assignedDate: today)
        review.duration = 1800
        context.insert(review)
        review.move(toSpace: work)

        let standup = Todo(title: "Standup", assignedDate: time(15, 30))
        standup.assignedHasTime = true
        standup.duration = 900
        context.insert(standup)
        standup.move(toSpace: work)

        let design = Todo(title: "Write the design doc", assignedDate: today)
        design.duration = 3600
        context.insert(design)
        design.move(toSpace: work)
        design.setState(.started)

        let bill = Todo(title: "Pay the *electricity* bill", assignedDate: today, dueDate: today)
        context.insert(bill)
        bill.move(toSpace: home)

        // A long title, so previews show the multi-line wrapping.
        let longTitle = Todo(
            title: "Draft the quarterly planning document and circulate it to the whole team",
            assignedDate: today
        )
        context.insert(longTitle)
        longTitle.move(toSpace: home)

        // Overdue, which renders in red.
        let passport = Todo(title: "Renew passport", dueDate: day(-3))
        context.insert(passport)

        // Week-planned work with no day of its own, so This Week and Next Week
        // are populated in previews and in the running app. Without these both
        // lists render empty and the only thing on screen is the empty state.
        let taxes = Todo(title: "Sort out the **tax** paperwork", weekSchedule: .thisWeek)
        context.insert(taxes)

        let trip = Todo(title: "Book the flights for the trip", weekSchedule: .nextWeek)
        context.insert(trip)
        trip.move(toSpace: home)

        // A live recurring series, so the running app shows a real occurrence
        // with the recurring glyph and the schedule chip rather than needing
        // one to be set up by hand first.
        let plants = Todo(title: "Water the plants", assignedDate: today)
        context.insert(plants)
        plants.move(toSpace: home)
        plants.recurrenceRule = RecurrenceRule(
            mode: .onSchedule, frequency: .weekly, interval: 1, weekdays: [2, 5]
        )
        // The date seeds the first occurrence and then comes off the template,
        // exactly as `setRecurrence` does it — a template holding a date of its
        // own draws a row claiming to be overdue.
        plants.clearScheduleForTemplate()
        plants.refileForCurrentScheduling()
        RecurrenceEngine(context: context).generateInstances(for: plants)

        // And a paused one, which the spec asks to surface in Anytime marked as
        // a schedule rather than a task.
        let filters = Todo(title: "Replace the air filters")
        context.insert(filters)
        filters.recurrenceRule = RecurrenceRule(
            mode: .afterCompletion, frequency: .monthly, interval: 3, status: .paused
        )
        filters.refileForCurrentScheduling()

        // Inbox: one plain, one imported and still unseen.
        let milk = Todo(title: "Buy oat milk")
        context.insert(milk)

        let dentist = Todo(title: "Book dentist appointment")
        dentist.importedFromReminders = true
        dentist.sourceReminderID = "preview-reminder"
        dentist.notes = "Ask about the crown."
        context.insert(dentist)
        dentist.markAsNew()

        // A reminder, so the bell badge appears.
        let reminder = Reminder(kind: .dateTime, fireDate: time(9), todo: review)
        context.insert(reminder)

        // Something resolved, for the Logbook.
        let archived = Todo(title: "Ship the beta")
        context.insert(archived)
        archived.setState(.completed)

        try? context.save()
    }

    // MARK: Lookups

    /// First todo matching a title prefix, for previews that need a specific
    /// one. Falls back to any todo so a preview never crashes on a rename.
    static func todo(titled prefix: String) -> Todo {
        let all = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        return all.first { $0.title.hasPrefix(prefix) } ?? all[0]
    }

    static var project: Todo { todo(titled: "Q3 Launch") }
    static var longTitled: Todo { todo(titled: "Draft the quarterly") }
    static var imported: Todo { todo(titled: "Book dentist") }

    static var space: Space {
        let all = (try? context.fetch(FetchDescriptor<Space>())) ?? []
        return all.first { $0.name == "Work" } ?? all[0]
    }

    /// Sample pending reminders for the import UI, which otherwise needs
    /// EventKit access the canvas does not have.
    static let pendingReminders: [PendingReminder] = [
        PendingReminder(
            id: "preview-1",
            title: "Pick up dry cleaning",
            notes: nil,
            dueDate: Calendar.current.date(byAdding: .day, value: 1, to: Date()),
            dueHasTime: false,
            listTitle: "Reminders"
        ),
        PendingReminder(
            id: "preview-2",
            title: "Call the plumber",
            notes: "Leaking tap in the kitchen",
            dueDate: nil,
            dueHasTime: false,
            listTitle: "Home"
        ),
    ]
}

extension View {
    /// Attach the shared preview container and settings.
    ///
    /// Views read `AppSettings` from the environment and `Todo` from the model
    /// context, so a preview missing either crashes rather than rendering.
    func previewEnvironment() -> some View {
        self
            .modelContainer(PreviewData.container)
            .environment(AppSettings.shared)
    }
}
#endif
