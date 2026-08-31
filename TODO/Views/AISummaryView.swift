//
//  AISummaryView.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//
import SwiftUI
import WeatherKit
import SwiftData

struct AISummaryView : View {
    
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @StateObject var weatherService = TodoWeatherService.shared
    @StateObject var aiSummaryService = AISummaryService(userInfo: .default)
    @State var summary: AISummary?
    /// Shared with the calendar so both read the same loaded range.
    @State private var eventStore = CalendarEventStore.shared
    @State private var showAIDebugView = false
    
    @Query private var savedSummaries: [SavedAISummary]

    /// Dated, unresolved work — the pool behind every card on this screen.
    ///
    /// The summary asks three questions of it (today, tomorrow, overdue) and
    /// all three are windows on the same set, so one predicate serves them all.
    /// Undated capture and resolved history can never answer any of them, and
    /// are now excluded by SQLite rather than by three separate in-memory
    /// passes over the whole store.
    ///
    /// `TodoQueries.today`/`tomorrow`/`overdue` still run over this, which is
    /// what keeps their exact date and Focus rules — they are just running over
    /// the dated rows instead of every row.
    @Query(TodoQueries.datedUnresolvedDescriptor())
    var todos: [Todo]

    /// Tapping the schedule card. The Today tab wires this to the calendar.
    var onOpenSchedule: (() -> Void)?
    /// Tapping the Any Time card. The Today tab wires this to the Today list.
    var onOpenAnyTime: (() -> Void)?
    
    var timeOfDay: String {
        TimeOfDay.from(date: .init()).rawValue
    }
    
    var nameGreeting: String {
        settings.userInfo.name.map {
            " \($0)"
        } ?? ""
    }

    /// Load today's events for the inline calendar.
    ///
    /// Access is only requested if the user has turned calendar events on, so
    /// the summary never prompts for a permission the feature does not use.
    private func loadEvents() async {
        guard settings.showCalendarEvents else {
            eventStore.clear()
            return
        }
        if !eventStore.hasAccess {
            guard await eventStore.requestAccess() else { return }
        }

        let calendar = settings.calendar
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        await eventStore.loadEvents(from: start, to: end, calendarIdentifiers: settings.visibleCalendars)
    }
    
    
    /// Greeting and generated text, on glass.
    ///
    /// One panel rather than a card per bullet: the summary is a single piece
    /// of prose, and slicing it up would make the screen read as a list of
    /// unrelated notes.
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Good \(timeOfDay)\(nameGreeting)")
                    .font(.largeTitle)
                    .fontWeight(.medium)
                Spacer()
                if settings.developerDebugMode || true {
                    Button {
                        showAIDebugView = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }

            if let summary {
                if let quickSummary = summary.quickSummary {
                    Text(
                        (try? AttributedString(markdown: quickSummary)) ??
                        AttributedString(quickSummary)
                    )
                    .font(.headline)
                }
                if summary.detailedSummary.count > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.detailedSummary, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").fontWeight(.bold)
                                Text(
                                    (try? AttributedString(markdown: bullet)) ??
                                    AttributedString(bullet)
                                )
                            }
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                HStack {
                    ProgressView()
                        .tint(.white)
                    Text("Summarizing your day...")
                        .font(.subheadline)
                }
            }
        }
        .sheet(isPresented: $showAIDebugView) {
            DebugAISummaryView(aiSummaryService: aiSummaryService)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .padding([.top], 10)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The panel grows as the generated text replaces the spinner; without
        // this the card snaps to its full height in one frame.
        .animation(Theme.Animation.listChange, value: summary?.quickSummary)
        .animation(Theme.Animation.listChange, value: summary?.detailedSummary)
    }

    /// The schedule and Any Time cards, or a single "All clear" in their place.
    ///
    /// Each card hides itself when it has nothing to show; this decides what to
    /// do when that leaves nothing at all. The emptiness checks come from the
    /// cards themselves (`hasContent`) rather than being reimplemented here, so
    /// the placement and the card can never disagree about whether it is empty.
    ///
    /// Wrapped in a `TimelineView` because whether the schedule card has content
    /// depends on the time of day: the last meeting ending has to make the card
    /// give way to "All clear" on its own, not at the next redraw that happens
    /// for some unrelated reason.
    private var dayCards: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let schedule = InlineCalendarCard(
                todos: todos,
                events: eventStore.events,
                calendar: settings.calendar,
                defaultDuration: settings.defaultEventDuration,
                onOpen: onOpenSchedule
            )
            let hasSchedule = schedule.hasContent(now: context.date)
            let hasAnyTime = TodoListCard.hasContent(todos: todos)

            VStack(spacing: 14) {
                if hasSchedule || hasAnyTime {
                    if hasSchedule { schedule }
                    if hasAnyTime { TodoListCard(todos: todos, onOpen: onOpenAnyTime) }
                } else {
                    AllClearCard()
                }
            }
            // Finishing the last thing swaps the cards for "All clear" rather
            // than making it appear where they were cut.
            .animation(Theme.Animation.listChange, value: hasSchedule)
            .animation(Theme.Animation.listChange, value: hasAnyTime)
        }
    }

    var body: some View {
        ZStack {
            SummaryBackgroundView(background: settings.summaryBackground)
                // Changing the backdrop in Settings crosses over rather than
                // cutting, which is jarring on something filling the screen.
                .id(settings.summaryBackground)
                .transition(.opacity)
                .animation(Theme.Animation.panel, value: settings.summaryBackground)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The greeting and the generated text are the one thing not
                    // on a card of its own, so they get their own glass panel
                    // rather than sitting on the photo.
                    summaryPanel

                    // The cards stand on their own: they render from local data,
                    // so the glance at today's weather, schedule, and list is
                    // there immediately rather than waiting on the model.
                    Spacer().frame(height: 14)

                    VStack(spacing: 14) {
                        WeatherSummaryCard(forecast: weatherService.weather)

                        dayCards
                    }
                }
                .padding([.leading, .trailing])
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .task(id: settings.showCalendarEvents) { await loadEvents() }
        .task { await refreshSummary() }
        .onChange(of: weatherService.weather) {
            Task { await refreshSummary() }
        }
    }

    /// Show the saved summary if it still describes the current day, otherwise
    /// generate a new one.
    ///
    /// The saved fingerprint is what decides, not the clock: a summary from
    /// earlier today is only still true if the tasks, events, forecast, user
    /// info, and instructions behind it have not moved. `generatedOn` still
    /// gates on the day so a summary never survives midnight, since the
    /// fingerprint deliberately leaves the date out.
    @MainActor
    private func refreshSummary() async {
        let now = Date()
        let filterPast: (Todo) -> Bool = { todo in
            todo.endDate.map { now <= $0 } ?? true
        }
        aiSummaryService.userInfo = settings.userInfo
        aiSummaryService.weather = weatherService.weather
        aiSummaryService.visibleCalendars = settings.visibleCalendars
        aiSummaryService.reminders = .init(
            scheduled: TodoQueries.today(todos).filter(filterPast).map { $0.toStruct() },
            overdue: TodoQueries.overdue(todos).filter(filterPast).map { $0.toStruct() }
        )
        // Needed once the day winds down, when the summary starts looking ahead
        // rather than listing what is left.
        aiSummaryService.tomorrow = TodoQueries.tomorrow(todos).map { $0.toStruct() }

        let saved = savedSummaries.first { Calendar.current.isDateInToday($0.generatedOn) }
        if let saved, await saved.fingerprint.matches(aiSummaryService.fingerprint(now: now)) {
            summary = saved.summary
            return
        }

        guard let (generated, fingerprint) = await aiSummaryService.generateSummary() else { return }
        summary = generated
        TodoStore(context: context).updateAISummary(
            .init(summary: generated, fingerprint: fingerprint)
        )
    }
}

struct DebugAISummaryView: View {
    var aiSummaryService: AISummaryService
    /// Built in a `task` rather than in `body`: the fingerprint reads the
    /// user's calendars, which is a cross-process call that must not sit in a
    /// view body.
    @State private var instructions: String?

    var body: some View {
        ScrollView {
            Text(instructions ?? "Loading…")
                .lineLimit(1...)
                .padding()
        }
        .task {
            instructions = await aiSummaryService.fingerprint().instructions.description
        }
    }
}


#if DEBUG

#Preview("AISummary") {
    DebugAISummaryView(aiSummaryService: .init(userInfo: .default))
}

#Preview {
    AISummaryView(
        summary: .init(
            quickSummary: "Busy day ahead with multiple tasks scheduled and **high precipitation expected**.",
            detailedSummary: [
                "Today is a busy day with several tasks scheduled.",
                "You have a pending 'Test' task with notes about cleaning the kitchen—floor, stove, fridge, and microwave—that **has** a state of 'started' and was assigned on 8/7/26.",
                "Additionally, there are two overlapping tasks on 8/8/26: 'Overlap1' from 2:00 PM for 1 hour, and 'Overlap2' from 2:10 PM for 1 hour, both with a state of 'open' and no due date.",
                "The weather in your location is warm and rainy, with high temperatures reaching up to 98.2°F and significant precipitation throughout the week, so you should dress for warm, wet conditions.",
                "Your day includes both indoor cleaning and scheduled tasks, with a commute likely involving weather-related considerations."
                ]
        )
    )
        .padding(.top)
        .previewEnvironment()
}

#endif
