//
//  SummaryFingerprint.swift
//  TODO
//
//  Created by John Rizkalla on 8/11/26.
//

import Foundation

// The type itself lives in `Models/SummaryFingerprintModel.swift` so the widget
// extension, which persists `SavedAISummary` but knows nothing about weather,
// calendars, or settings, can compile it without dragging those in. This file
// holds the builders, which need all three.

extension SummaryFingerprint {

    /// Dates are formatted at whole-minute resolution and in a fixed locale.
    ///
    /// Fixed because the fingerprint is only ever compared with another
    /// fingerprint: a localized string would make the summary look stale after
    /// a region change, and sub-minute precision would let a re-read of the
    /// same event produce a different line.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        formatter.timeZone = .current
        return formatter
    }()

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "none" }
        return dateFormatter.string(from: date)
    }

    static func user(_ info: UserInfo) -> [String] {
        [
            "name: \(info.name ?? "none")",
            "info: \(info.generalInfomation ?? "none")",
            "memory: \(info.memory ?? "none")",
        ]
    }

    static func weather(_ forecast: WeatherForecast?) -> [String] {
        guard let forecast else { return [] }
        let daily = forecast.daily
        // Guard against the parallel arrays disagreeing rather than trusting
        // `time` to be the shortest: a truncated response should produce a
        // shorter fingerprint, not a crash.
        let count = min(
            daily.time.count,
            daily.temperatureMax.count,
            daily.temperatureMin.count,
            daily.precipitationProbabilityMax.count
        )
        let location = "location: \(forecast.latitude),\(forecast.longitude) \(forecast.timezone)"
        return [location] + (0..<count).map { i in
            let precipitation = daily.precipitationProbabilityMax[i]?.description ?? "none"
            return "\(daily.time[i]): \(daily.temperatureMin[i])-\(daily.temperatureMax[i]) p\(precipitation)"
        }
    }

    /// One line per to-do, covering every field `TodoStruct.promptRepresentation`
    /// puts in front of the model.
    static func todos(_ list: RelevantTodoList?) -> [String] {
        guard let list else { return [] }
        return list.scheduled.map { line(for: $0, bucket: "scheduled") }
            + list.overdue.map { line(for: $0, bucket: "overdue") }
    }

    /// Tomorrow's to-dos, which the evening and night instructions look ahead to.
    ///
    /// Folded into the same `todos` list as today's rather than given a field of
    /// their own: the bucket prefix already keeps them distinct, and a saved
    /// fingerprint from before this existed still simply fails to match.
    static func tomorrow(_ todos: [TodoStruct]) -> [String] {
        todos.map { line(for: $0, bucket: "tomorrow") }
    }

    private static func line(for todo: TodoStruct, bucket: String) -> String {
        [
            bucket,
            todo.isProject ? "project" : "todo",
            todo.title,
            todo.notes,
            todo.state?.rawValue ?? "none",
            "assigned:\(stamp(todo.assignedDate))\(todo.assignedHasTime ? "+t" : "")",
            "due:\(stamp(todo.dueDate))\(todo.dueHasTime ? "+t" : "")",
            "duration:\(todo.duration?.description ?? "none")",
            "space:\(todo.space?.name ?? "none")",
            "parent:\(todo.parentTitle ?? "none")",
        ].joined(separator: "|")
    }

    /// One line per event, covering every field `CalendarEvent.promptRepresentation`
    /// puts in front of the model.
    ///
    /// Sorted by the resulting line rather than left in load order: the same set
    /// of events coming back in a different order is not a change the model
    /// would notice.
    static func events(_ events: [CalendarEvent]) -> [String] {
        events.map { event in
            [
                event.id,
                event.title,
                stamp(event.start),
                stamp(event.end),
                "allDay:\(event.isAllDay)",
                "calendar:\(event.calendarTitle)",
                "location:\(event.location ?? "none")",
            ].joined(separator: "|")
        }.sorted()
    }
}
