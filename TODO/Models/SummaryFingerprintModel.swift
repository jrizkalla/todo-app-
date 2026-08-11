//
//  SummaryFingerprintModel.swift
//  TODO
//
//  Created by John Rizkalla on 8/11/26.
//

import Foundation

/// A flat, comparable stand-in for the prompt the model was last given.
///
/// Saved alongside the generated summary so reopening Today can decide whether
/// the cached text still describes the current state of the day. It is compared
/// with `==`, never parsed, so the exact wording of each line does not matter —
/// only that a line changes when the thing it describes changes.
///
/// Deliberately *not* included: the current date and time. Those move
/// constantly, and treating them as inputs would invalidate the summary on
/// every glance. Staleness by age is a separate question, answered by
/// `SavedAISummary.generatedOn`.
///
/// The lines are built in `Services/SummaryFingerprint.swift`. Only the stored
/// shape lives here, because the widget extension persists `SavedAISummary` and
/// so must be able to compile this type without the weather, calendar, and
/// settings types the builders depend on.
struct SummaryFingerprint: Codable, Equatable {
    /// The instruction text handed to the model. Editing the wording of the
    /// instructions is a real change to the prompt, so it re-runs.
    var instructions: String = ""
    /// User name, description, and memory.
    var user: [String] = []
    /// The forecast, one line per day.
    var weather: [String] = []
    /// Scheduled and overdue to-dos, one line each.
    var todos: [String] = []
    /// Upcoming calendar events, one line each.
    var events: [String] = []

    /// Whether a saved fingerprint is close enough to reuse its summary.
    ///
    /// Everything here is either present or it is not, so "significantly
    /// different" is exact inequality: the lists are already built from only
    /// the fields that are fed to the model, which means any difference at all
    /// is a difference the model would have seen.
    func matches(_ other: SummaryFingerprint) -> Bool {
        self == other
    }
}
