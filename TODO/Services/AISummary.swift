//
//  AISummary.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//

import CoreLocation
import FoundationModels
import Combine

struct RelevantTodoList : PromptRepresentable {
    let scheduled: [TodoStruct]
    let overdue: [TodoStruct]
    
    var promptRepresentation: Prompt {
        "Scheduled TODOs:"
        scheduled
        
        "Overdue TODOs"
        overdue
    }
}

enum TimeOfDay: String {
    case morning, afternoon, evening, night
    
    static func from(date: Date) -> Self {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<12:
            .morning
        case 12..<(12+5):
            .afternoon
        case (12+5)..<(12+9):
            .evening
        default:
            .night
        }
    }
}



final class AISummaryService: ObservableObject {
//    let location: CLLocation?
    var weather: WeatherForecast?
    var reminders: RelevantTodoList?
    var userInfo: UserInfo
    var visibleCalendars: [String] = []
    
    var session: LanguageModelSession!
    
    init(userInfo: UserInfo) {
        self.weather = nil
        self.reminders = nil
        self.userInfo = userInfo
    }
    
    func generateSummary() async -> AISummary? {
        guard SystemLanguageModel.default.isAvailable else {
            print("model isn't available")
            return nil
        }
        
        let calEventStore = CalendarEventStore()
        let now = Date()
        calEventStore.loadEvents(
            from: Calendar.current.startOfDay(for: now),
            to: Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60 - 1),
            calendarIdentifiers: visibleCalendars
        )
        
        let prompt = Prompt {
            
            "Current date/time: \(now.description(with: .current))"
            
            "Information about the user:"
            "name: \(userInfo.name ?? "none")"
            "User provided description: \(userInfo.generalInfomation ?? "none")"
            
            if let weather {
                weather
            }
            if let reminders {
                reminders
            }
            
            "Calendar events:"
            calEventStore.events
        }
        
        if session == nil {
            session = LanguageModelSession(
                instructions: Self.getInstructions(for: .from(date: now))
            )
        }
        do {
            let response = try await session.respond(to: prompt)
            let responseData = String(response.content.trimmingPrefix(/\s*```json\s*/)).trimmingSuffix("```")
            let decoder = JSONDecoder()
            return try? decoder.decode(AISummary.self, from: responseData.data(using: .utf8)!)
        } catch {
            print(error)
            return nil
        }
    }
}


extension AISummaryService {
    
    static func getInstructions(for timeOfDay: TimeOfDay) -> String {
        let rest = switch timeOfDay {
        case .morning, .afternoon:
            moringInstructions
        case .evening, .night:
            afternoonInstructions
        }
        return commonInstructions.appending(rest)
    }
    static let commonInstructions = """
    You are a personal assistant telling the user about their day. Your job is to give a brief overview of their day and to highlight important information. They have access to all of the information you have so your job is not to be complete but to provide a summary and point out anything that might need urgent attention.
    
    The included prompt may include:
    - The current location, date, and time
    - A list of todo items scheduled today
    - A list of todo items due today
    - A list of calendar events scheduled for today
    - Other user information
    
    Provide the output as JSON in the following format: 
    {
      "quickSummary": "One sentence summary headline of the day. Do not exceed 10 words".
      "detailedSummary": [
        "Bulleted list of items summarizing their day",
        "Each item in the array is an item in the list"
      ]
    }
    
    """
    
    static let moringInstructions = """
    The user is starting their day. They need to know how to prepare for the day before they head out (if they need to leave their house).
    Tell them what they need to do to prepare for the day.
    """
    
    static let afternoonInstructions = ""
    static let modelInstructions = """
        You are a personal assistant trying to organize the day for the user.
        Use the provided information to give the user a summary of their day.
        Do not just mirror the information provided. The user has access to all of this information.
        Instead, use this information to tell the user how to prepare for the day like:
        - How to dress for the weather
        - What their commute looks like
        - How busy their day is and where they'll be spending it
        etc.
        
        The provided information may include:
        - The current weather for the user's location
        - A list of todo items scheduled today
        - A list of todo items due today & tomorrow
        - A list of calendar events scheduled for today
        - User Information
        
        Look at all the details of items provided. Take into consideration the calendar event locations, timings of events and reminders, due dates, etc.
        
        You can remember information about the user via userInfo.memory
        
        Provide the response as JSON with the following format:
        {
            "quickSummary": One sentence summary of the day. Do not exceed 10 words
            "detailedSummary": Detailed summary of the day. Under a paragraph long. Use Markdown to format the summary as a bullet list. Add any other formatting needed.
        }
        
        The text should be formatted like you are talking to the user directly. The text should also be punctuated correctly.
        

        The output will be fed verbatim to a JSON decoder and it must decode correctly.
        """
}

/*
         Here is an fictional example response. Follow this template but don't use any of the information in it because it is all made up.
        {
            "quickSummary": "Busy morning followed by a fun evening",
            "detailedSummary": "Your morning starts at *9am* with a meeting in the office.
        Make sure you dress for *light rain* and maybe budget extra time for the commute. The changes of rain around the time you're commuting is 85%.
        During the day, you're going to work on your app.
        You have a dinner planned in the evening at Chick-Fil-A, make sure you leave the office before 5:30pm to have enough time to prepare for dinner."
        }
 */

extension CalendarEvent: PromptRepresentable {
    var promptRepresentation: Prompt {
        "Calendar event:"
        "\t\(title)"
        "\t\(start.description(with: .current)) - \(end.description(with: .current))"
        "\tAll day: \(isAllDay)"
        "\tCalendar: \(calendarTitle)"
        "\tLocation: \(location ?? "none")"
    }
}
