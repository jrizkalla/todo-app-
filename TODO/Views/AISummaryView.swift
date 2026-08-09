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
    @StateObject var weatherService = TodoWeatherService.shared
    @StateObject var aiSummaryService = AISummaryService(userInfo: .default)
    @State var summary: AISummary?
    /// Shared with the calendar so both read the same loaded range.
    @State private var eventStore = CalendarEventStore.shared

    @Query var todos: [Todo]
    
    var timeOfDay: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 4..<12:
            "morning"
        case 12..<(12+5):
            "afternoon"
        case (12+5)..<(12+9):
            "evening"
        default:
            "night"
        }
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

        eventStore.loadEvents(from: start, to: end, calendarIdentifiers: settings.visibleCalendars)
    }
    
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Good \(timeOfDay)\(nameGreeting)")
                    .font(.largeTitle)
                    .fontWeight(.medium)
                Spacer().frame(height: 50)

                if let summary {
                    if let quickSummary = summary.quickSummary {
                        Text(
                            (try? AttributedString(markdown: quickSummary)) ??
                            AttributedString(quickSummary)
                        ).font(.headline)
                        Spacer().frame(height: 8)
                    }
                    if let detailedSummary = summary.detailedSummary {
                        Text(
                            (try? AttributedString(markdown: detailedSummary)) ??
                            AttributedString(detailedSummary)
                        )
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("Summarizing your day...")
                    }
                }

                // The cards stand on their own: they render from local data, so
                // the glance at today's weather, schedule, and list is there
                // immediately rather than waiting on the model.
                Spacer().frame(height: 24)

                VStack(spacing: 14) {
                    WeatherSummaryCard(forecast: weatherService.weather)

                    InlineCalendarCard(
                        todos: todos,
                        events: eventStore.events,
                        calendar: settings.calendar,
                        defaultDuration: settings.defaultEventDuration
                    )

                    TodoListCard(todos: todos)
                }
            }
            .padding([.leading, .trailing])
            .padding(.bottom, 24)
        }
        .task(id: settings.showCalendarEvents) { await loadEvents() }
        .onChange(of: weatherService.weather) {
            aiSummaryService.userInfo = settings.userInfo
            aiSummaryService.weather = weatherService.weather
            aiSummaryService.reminders = .init(
                scheduled: TodoQueries.today(todos).map { $0.toStruct() },
                overdue: TodoQueries.overdue(todos).map { $0.toStruct() }
            )
            Task { @MainActor in
                summary = await aiSummaryService.generateSummary()
            }
        }
    }
}


#if DEBUG

#Preview {
    AISummaryView(
        summary: .init(
            quickSummary: "Busy day ahead with multiple tasks scheduled and **high precipitation expected**.",
            detailedSummary: "Today is a busy day with several tasks scheduled. You have a pending 'Test' task with notes about cleaning the kitchen—floor, stove, fridge, and microwave—that **has** a state of 'started' and was assigned on 8/7/26. Additionally, there are two overlapping tasks on 8/8/26: 'Overlap1' from 2:00 PM for 1 hour, and 'Overlap2' from 2:10 PM for 1 hour, both with a state of 'open' and no due date. The weather in your location is warm and rainy, with high temperatures reaching up to 98.2°F and significant precipitation throughout the week, so you should dress for warm, wet conditions. Your day includes both indoor cleaning and scheduled tasks, with a commute likely involving weather-related considerations."
        )
    )
        .padding(.top)
        .previewEnvironment()
}

#endif
