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

struct AISummary: Codable {
    var quickSummary: String?
    var detailedSummary: String?
}


final class AISummaryService: ObservableObject {
//    let location: CLLocation?
    var weather: WeatherForecast?
    var reminders: RelevantTodoList?
//    let calendarEvents: [CalendarEvent]
    var userInfo: UserInfo
    
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
        
        let prompt = Prompt {
            
            "Information about the user:"
            "name: \(userInfo.name ?? "none")"
            "User provided description: \(userInfo.generalInfomation ?? "none")"
            
            if let weather {
                weather
            }
            if let reminders {
                reminders
            }
        }
        
        if session == nil {
            session = LanguageModelSession(
                instructions: Self.modelInstructions,
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
        
        Example response (assumes the user has 2 calendar events and a todo: a meeting at 9am with a set location, another event at 6:30 pm titled "dinner", and a todo at 11am to "work on app"):
        {
            "quickSummary": "Busy morning followed by a fun evening",
            "detailedSummary": "Your morning starts at *9am* with a meeting in the office.
        Make sure you dress for *light rain* and maybe budget extra time for the commute. The changes of rain around the time you're commuting is 85%.
        During the day, you're going to work on your app.
        You have a dinner planned in the evening at Chick-Fil-A, make sure you leave the office before 5:30pm to have enough time to prepare for dinner."
        }
        
        The output will be fed verbatim to a JSON decoder and it must decode correctly.
        """
}
