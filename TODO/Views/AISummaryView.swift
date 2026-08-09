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
    
    
    var body: some View {
        VStack(alignment: .leading) {
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
        }
        .padding([.leading, .trailing])
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
