//
//  AISummary.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//

import CoreLocation
import FoundationModels
import Combine
import OSLog

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

    /// What the assistant has learned about the user, or `nil` when memory is
    /// off or empty. Part of every prompt.
    var memory: String?

    /// Whether the model is asked to write new facts down.
    ///
    /// Separate from `memory` being non-nil, because the two are genuinely
    /// independent: the first day with memory on has nothing to recall but
    /// everything to learn. Off means the instructions never mention memory at
    /// all, rather than asking for facts the caller then throws away — which
    /// spends tokens on every summary and invites a stray tag in the output.
    var isRemembering = true

    /// The session the most recent summary was written in.
    ///
    /// Rebuilt for every summary rather than carried forward: a session is
    /// bound to its instructions, and those change as the day moves between
    /// phases. It is kept afterwards only so the chat can continue it — `ask`
    /// answers follow-ups in the transcript that produced the text on screen.
    var session: LanguageModelSession!

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
            instructions: Self.getInstructions(
                for: phase(now: now, events: events),
                remembering: isRemembering
            ),
            user: SummaryFingerprint.user(userInfo) + SummaryFingerprint.memory(memory),
            weather: SummaryFingerprint.weather(weather),
            todos: SummaryFingerprint.todos(reminders) + SummaryFingerprint.tomorrow(tomorrow),
            events: SummaryFingerprint.events(events)
        )
    }

    /// Everything the model is told about the day, short of the instructions.
    ///
    /// Built here rather than inline in `generateSummary` because the chat asks
    /// the same question of the same day: a follow-up about what is left has to
    /// be answered from the same facts the summary was written from, or the two
    /// will contradict each other on screen.
    func dayPrompt(now: Date, events: [CalendarEvent]) -> Prompt {
        Prompt {
            "Current date/time: \(now.description(with: .current))"

            "Information about the user:"
            "name: \(userInfo.name ?? "none")"
            "User provided description: \(userInfo.generalInfomation ?? "none")"

            if let memory, !memory.isEmpty {
                "What you remember about this user from previous days:"
                memory
            }

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
    }

    /// The generated summary, the fingerprint of the prompt that produced it,
    /// and anything the model asked to remember.
    func generateSummary()
    async -> (summary: AISummary, fingerprint: SummaryFingerprint, facts: [String])? {
        guard SystemLanguageModel.default.isAvailable else {
            AppLog.data.warning("The system language model is not available")
            return nil
        }

        let now = Date()
        let events = await upcomingEvents(now: now)
        let instructions = Self.getInstructions(
            for: phase(now: now, events: events),
            remembering: isRemembering
        )
        let prompt = dayPrompt(now: now, events: events)

        // Built from the same values the prompt just consumed rather than by
        // re-reading them, so the two can never describe different days.
        let fingerprint = SummaryFingerprint(
            instructions: instructions,
            user: SummaryFingerprint.user(userInfo) + SummaryFingerprint.memory(memory),
            weather: SummaryFingerprint.weather(weather),
            todos: SummaryFingerprint.todos(reminders) + SummaryFingerprint.tomorrow(tomorrow),
            events: SummaryFingerprint.events(events)
        )

        // A fresh session per summary, always — not reused when the
        // instructions happen to match. The transcript by then holds the
        // previous summary and every chat turn since, so reusing it would grow
        // the context all day and let a passing question steer the next
        // summary. The day's facts are in the prompt, so there is nothing in
        // that history the new summary needs.
        //
        // The chat is the opposite case and deliberately does reuse this
        // session: see `ask`.
        session = LanguageModelSession(instructions: instructions)

        do {
            let response = try await session.respond(to: prompt)
            // Memory is pulled out before the JSON is parsed: the model is
            // asked to emit the facts outside the object, so leaving them in
            // would make the whole response fail to decode.
            let (facts, body) = MemoryStore.extract(from: response.content)
            let responseData = String(body.trimmingPrefix(/\s*```json\s*/))
                .trimmingSuffix("```")
            guard let summary = try? JSONDecoder().decode(
                AISummary.self,
                from: Data(responseData.utf8)
            ) else { return nil }
            return (summary, fingerprint, facts)
        } catch {
            AppLog.data.error("Summary generation failed: \(error, privacy: .public)")
            // Cleared rather than left in place so the chat stays closed,
            // instead of offering to continue a conversation about a summary
            // that was never written.
            session = nil
            return nil
        }
    }

    /// Ask a follow-up question in the session the summary was written in.
    ///
    /// The same session, deliberately: it already holds the day's prompt and
    /// the summary it produced, so "why is that urgent?" resolves against the
    /// text on screen rather than against a cold model that would have to be
    /// re-fed the whole day and might describe it differently.
    ///
    /// Returns the reply with any memory block stripped, plus the facts it
    /// held, so the caller can save them the same way the summary's are saved.
    ///
    /// - Returns: `nil` when no summary has been generated yet, which is also
    ///   when the chat is not offered.
    func ask(_ question: String) async throws -> (reply: String, facts: [String])? {
        guard let session else { return nil }
        let response = try await session.respond(to: Prompt {
            Self.chatInstructions
            "The user asks: \(question)"
        })
        let (facts, cleaned) = MemoryStore.extract(from: response.content)
        return (cleaned, facts)
    }

    /// Whether a follow-up can be asked right now.
    ///
    /// False until the first summary lands, since the chat's whole premise is
    /// continuing that conversation.
    var canChat: Bool { session != nil }

    /// Reduce a grown memory file back to its durable facts.
    ///
    /// Returns `nil` on any failure, and the caller leaves the file alone. An
    /// over-long memory is a much smaller problem than an emptied one, so every
    /// doubt resolves towards keeping what is already there.
    ///
    /// This is the one call that can *lose* what the assistant knows, and it
    /// runs on the same small on-device model as everything else — which is
    /// exactly why the result is checked rather than trusted. See
    /// `isPlausibleCompaction`.
    func compactMemory(_ text: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let session = LanguageModelSession(instructions: Self.memoryCompactionInstructions)
        do {
            let response = try await session.respond(to: Prompt {
                "Here is the current memory file, one fact per line:"
                text
            })
            let compacted = String(response.content.trimmingPrefix(/\s*```(\w+)?\s*/))
                .trimmingSuffix("```")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard Self.isPlausibleCompaction(of: text, into: compacted) else {
                AppLog.data.warning("Discarded an implausible memory compaction")
                return nil
            }
            return compacted
        } catch {
            AppLog.data.error("Memory compaction failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// The floor a compaction has to clear to be written back.
    ///
    /// Consolidation should merge duplicates and drop one-off noise, so the
    /// file legitimately shrinks — but a small model asked to rewrite a long
    /// list can instead summarize it into a sentence, or answer with a
    /// preamble, and the result would silently destroy everything the
    /// assistant had learned. Half the original line count is well below any
    /// honest consolidation of a file that only compacts once it has grown past
    /// the threshold, and well above a collapse.
    static func isPlausibleCompaction(of original: String, into compacted: String) -> Bool {
        let lines = { (text: String) in
            text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
        }
        let before = lines(original)
        let after = lines(compacted)

        // An empty result is a failure, not an instruction to forget.
        guard after > 0 else { return false }
        // Nothing to judge against; let it through rather than wedging the file.
        guard before > 0 else { return true }

        return Double(after) >= Double(before) * minimumCompactionRatio
    }

    /// See `isPlausibleCompaction`.
    static let minimumCompactionRatio = 0.5
}


extension AISummaryService {

    static func getInstructions(for phase: SummaryPhase, remembering: Bool = true) -> String {
        let rest = switch phase {
        case .morning: morningInstructions
        case .midday: middayInstructions
        case .evening: eveningInstructions
        case .night: nightInstructions
        }
        let base = commonInstructions.appending(rest)
        return remembering ? base.appending("\n\n").appending(memoryInstructions) : base
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

    /// Appended to every set of instructions when memory is on.
    ///
    /// The rule that matters is the last one: the point of a memory is to hold
    /// what is still true next month, and a model left to its own judgment will
    /// happily write down today's to-do list. Everything above it exists to
    /// make "durable" concrete enough to act on.
    static let memoryInstructions = """
    You keep a memory of things worth knowing about this user across days. Anything you are given under "What you remember about this user" came from you on a previous day — treat it as established and do not write it down again.

    After the JSON, if and only if you have learned something durable, add a memory block:

    \(MemoryStore.openTag)
    One fact per line, written as a short statement.
    \(MemoryStore.closeTag)

    Worth remembering: standing commitments and their rhythms, how they work and when they are productive, recurring people and places, stated preferences about how they want to be spoken to, constraints like a commute or a standing conflict.

    Never remember: individual tasks or events, anything about today specifically, anything already in your memory, or anything you inferred from a single occurrence. If a day gives you nothing durable, write no memory block at all — that is the normal case, and an empty block is worse than none.
    """

    /// Prefixed to each chat turn.
    ///
    /// Sent with every question rather than once at the start because the
    /// session's standing instructions are the summary's, and those demand
    /// JSON. Without this the model answers "what should I do first?" with a
    /// `quickSummary` object. Repeating it per turn is what keeps the answer
    /// in prose no matter how long the conversation runs.
    static let chatInstructions = """
    The user is now asking a follow-up question about the day you just summarized. Answer it directly, in plain prose — not JSON, and not the bulleted summary format you used above.

    Keep it conversational and short: a sentence or two unless they have asked for something that genuinely needs more. Answer only from the information you were given about their day. If they ask something you do not have the information for, say so plainly rather than guessing.

    If the question reveals something durable about them, record it with a memory block exactly as described in your instructions, after your answer.
    """

    /// Instructions for the periodic consolidation pass over the memory file.
    ///
    /// Framed as consolidation rather than summarization: the file is a set of
    /// facts, and what it needs is the duplicates merged and the stale ones
    /// dropped, not a paragraph describing what it used to say.
    static let memoryCompactionInstructions = """
    You are consolidating an assistant's memory file about one user. It has grown by accretion and needs tidying.

    Return the cleaned file and nothing else: no preamble, no explanation, no code fences. One fact per line, in the same short declarative style as the input.

    Rules:
    - Merge facts that say the same thing into the single clearest statement.
    - Where two lines conflict, keep the more specific one; if one is plainly an update of the other, keep the newer-sounding one.
    - Drop anything that reads as a one-off task, a single day's event, or a detail that has no bearing on future days.
    - Group related facts near each other so the file stays readable.
    - Preserve every distinct durable fact. This is consolidation, not summarization — losing something the user told you is the one failure that matters. When in doubt, keep the line.
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
