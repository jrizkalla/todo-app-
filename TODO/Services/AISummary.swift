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

/// Which set of instructions the model is given.
///
/// Distinct from `TimeOfDay`, which is the clock and drives the greeting. Only
/// the morning brief is really about the hour; past that, what the user wants
/// to hear depends on how much of the day is left to do. Someone who has
/// cleared everything by 2pm wants to hear about tomorrow, not a nudge about
/// remaining tasks — so the last three are chosen by what is left, not when.
enum SummaryPhase: String, CaseIterable {
    /// Starting the day: what to expect and how to prepare for it.
    case morning
    /// Work still to do: encouragement and what is left.
    case midday
    /// Down to the last thing or two: name them, then look ahead.
    case evening
    /// Nothing left: talk about tomorrow.
    case night

    /// The count at or below which the day counts as nearly done.
    ///
    /// "Only 1 or 2 tasks/calendar events left" from the spec.
    static let windingDownThreshold = 2

    /// - Parameters:
    ///   - date: used only to decide whether this is the morning brief.
    ///   - remaining: to-dos and upcoming events still outstanding.
    static func from(date: Date, remaining: Int) -> Self {
        // Nothing left outranks the hour: there is no point running the
        // morning "how to prepare" brief for a day with nothing in it.
        if remaining == 0 { return .night }
        if TimeOfDay.from(date: date) == .morning { return .morning }
        if remaining <= windingDownThreshold { return .evening }
        return .midday
    }
}



final class AISummaryService: ObservableObject {
//    let location: CLLocation?
    var weather: WeatherForecast?
    var reminders: RelevantTodoList?
    /// Tomorrow's to-dos, which the evening and night instructions look ahead to.
    var tomorrow: [TodoStruct] = []
    var userInfo: UserInfo
    /// `nil` means every calendar, matching `CalendarEventStore.loadEvents`.
    var visibleCalendars: [String]?
    
    var session: LanguageModelSession!
    /// The instructions `session` was built with.
    ///
    /// A session is bound to its instructions, so it has to be rebuilt when
    /// they change — otherwise crossing into a new time of day would keep
    /// prompting with the previous period's instructions, and the summary
    /// would never actually reflect the fingerprint that triggered it.
    private var sessionInstructions: String?

    init(userInfo: UserInfo) {
        self.weather = nil
        self.reminders = nil
        self.userInfo = userInfo
    }
    
    /// The upcoming events the prompt is built from.
    ///
    /// Loaded through here rather than inline so the fingerprint and the prompt
    /// are guaranteed to describe the same set of events.
    private func upcomingEvents(now: Date) async -> [CalendarEvent] {
        let calEventStore = CalendarEventStore()
        await calEventStore.loadEvents(
            from: now,
            to: Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60 - 1),
            calendarIdentifiers: visibleCalendars
        )
        return calEventStore.events
    }

    /// How much of the day is still outstanding: what the phase is chosen from.
    ///
    /// Unresolved to-dos plus events still ahead. Overdue items count — they are
    /// work the user still has to do, so a day with three of them left is not a
    /// day to talk about tomorrow.
    private func remainingCount(now: Date, events: [CalendarEvent]) -> Int {
        let todos = reminders.map { list in
            (list.scheduled + list.overdue).filter { $0.state?.isResolved != true }.count
        } ?? 0
        return todos + events.filter { $0.end > now }.count
    }

    /// The phase, and the instructions that go with it, for the current state.
    ///
    /// Derived in one place so the fingerprint and the prompt can never pick
    /// different instructions for the same moment.
    func phase(now: Date, events: [CalendarEvent]) -> SummaryPhase {
        .from(date: now, remaining: remainingCount(now: now, events: events))
    }

    /// A flat description of everything that would go into the prompt right now.
    ///
    /// Cheap by comparison with running the model, so the view calls this first
    /// and only generates when it does not match what was saved.
    func fingerprint(now: Date = Date()) async -> SummaryFingerprint {
        let events = await upcomingEvents(now: now)
        return SummaryFingerprint(
            instructions: Self.getInstructions(for: phase(now: now, events: events)),
            user: SummaryFingerprint.user(userInfo),
            weather: SummaryFingerprint.weather(weather),
            todos: SummaryFingerprint.todos(reminders) + SummaryFingerprint.tomorrow(tomorrow),
            events: SummaryFingerprint.events(events)
        )
    }

    /// The generated summary, paired with the fingerprint of the prompt that
    /// produced it so the caller can save both together.
    func generateSummary() async -> (summary: AISummary, fingerprint: SummaryFingerprint)? {
        guard SystemLanguageModel.default.isAvailable else {
            print("model isn't available")
            return nil
        }

        let now = Date()
        let events = await upcomingEvents(now: now)
        let instructions = Self.getInstructions(for: phase(now: now, events: events))

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
            events

            if !tomorrow.isEmpty {
                "Scheduled for tomorrow:"
                tomorrow
            }
        }

        // Built from the same values the prompt just consumed rather than by
        // re-reading them, so the two can never describe different days.
        let fingerprint = SummaryFingerprint(
            instructions: instructions,
            user: SummaryFingerprint.user(userInfo),
            weather: SummaryFingerprint.weather(weather),
            todos: SummaryFingerprint.todos(reminders) + SummaryFingerprint.tomorrow(tomorrow),
            events: SummaryFingerprint.events(events)
        )

        if session == nil || sessionInstructions != instructions {
            session = LanguageModelSession(instructions: instructions)
            sessionInstructions = instructions
        }
        do {
            let response = try await session.respond(to: prompt)
            let responseData = String(response.content.trimmingPrefix(/\s*```json\s*/)).trimmingSuffix("```")
            let decoder = JSONDecoder()
            guard let summary = try? decoder.decode(
                AISummary.self,
                from: responseData.data(using: .utf8)!
            ) else { return nil }
            return (summary, fingerprint)
        } catch {
            print(error)
            return nil
        }
    }
}


extension AISummaryService {

    static func getInstructions(for phase: SummaryPhase) -> String {
        let rest = switch phase {
        case .morning: morningInstructions
        case .midday: middayInstructions
        case .evening: eveningInstructions
        case .night: nightInstructions
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
    - A list of todo items scheduled for tomorrow
    - The weather forecast
    - Other user information

    Write as if you are speaking to the user directly, in the second person. Keep it short: at most four bullets, one sentence each. Do not repeat the raw list back to them — they can already see it. Never invent tasks, events, times, or weather that are not in the provided information.

    Provide the output as JSON in the following format:
    {
      "quickSummary": "One sentence summary headline of the day. Do not exceed 10 words".
      "detailedSummary": [
        "Bulleted list of items summarizing their day",
        "Each item in the array is an item in the list"
      ]
    }

    """

    static let morningInstructions = """
    The user is starting their day. Tell them what to expect from it and how to prepare before they head out.

    Cover, when the information supports it:
    - How to dress for the weather, and whether rain, heat, or cold will affect them
    - When their first commitment is, and by when they need to leave
    - How busy the day is overall and where it will be spent
    - Anything that needs attention early or that is easy to be caught out by

    If bad weather lines up with a time they need to be out, say so plainly and say what to do about it.
    """

    static let middayInstructions = """
    The user is partway through their day and still has work left.

    Tell them what is left to do and what to focus on next. Lead with whatever is time-sensitive: anything overdue, and anything with a time that is coming up soon.

    Be encouraging and matter-of-fact. Acknowledge what they have already gotten through when the information shows it, and keep the remaining work feeling manageable rather than listing it back as a pile. Do not be saccharine or over-praise them.
    """

    static let eveningInstructions = """
    The user is nearly done: only one or two things are left.

    Name those remaining items specifically so they know exactly what is left to close out the day. Then give a high-level look at tomorrow — the shape of it rather than a full rundown: how busy it is, the first thing on it, and anything they would want to prepare for tonight.

    Keep the tomorrow part brief. It is a heads-up, not a second summary. If nothing is scheduled for tomorrow, say the day is clear rather than padding it out.
    """

    static let nightInstructions = """
    The user has nothing left today. Do not give them a to-do list.

    Acknowledge that the day is done, briefly and without overdoing the praise. Then talk about tomorrow: how busy it looks, the first thing on the calendar and when it starts, anything worth preparing tonight, and the weather if it will affect them.

    If tomorrow is clear as well, say so and leave it there rather than manufacturing things for them to think about.
    """
}

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
