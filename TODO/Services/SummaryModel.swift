//
//  SummaryModel.swift
//  TODO
//
//  Created by John Rizkalla on 9/15/26.
//

import Foundation
import FoundationModels

/// Which of Apple's two foundation models a session runs against.
///
/// The day's first summary is worth the good model: it is the one that sets up
/// the framing, notices what actually matters, and writes the memory the rest of
/// the day is refined against. After that the inputs only drift — a task ticked
/// off, an event that has passed — and the on-device model is both quick enough
/// to keep up with that and free of the cloud's quota.
enum SummaryModel: String, Codable, Sendable {
    /// Private Cloud Compute. Larger, slower, rate-limited.
    case cloud
    /// The on-device system model. Always there, no quota.
    case local

    /// Whether this model can be reached right now.
    ///
    /// Cloud is unavailable on hardware that is not eligible and on systems
    /// older than the API, so every use of it has to be able to fall back.
    var isAvailable: Bool {
        switch self {
        case .local:
            return SystemLanguageModel.default.isAvailable
        case .cloud:
            guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                return false
            }
            return PrivateCloudComputeLanguageModel().isAvailable
        }
    }

    /// This model if it is available, otherwise the one that is.
    ///
    /// Callers ask for what they want and take what they get: a summary written
    /// on-device is far better than no summary because the good model was busy.
    var resolved: SummaryModel? {
        if isAvailable { return self }
        let fallback: SummaryModel = self == .cloud ? .local : .cloud
        return fallback.isAvailable ? fallback : nil
    }

    /// A session bound to this model and these instructions.
    ///
    /// Sessions are the unit of conversation in FoundationModels, so this is
    /// also what the chat holds on to — see `DayChatModel`, which reuses the
    /// session the summary was generated from so follow-up questions land in
    /// the same context rather than starting cold.
    func makeSession(instructions: String) -> LanguageModelSession {
        switch self {
        case .local:
            return LanguageModelSession(instructions: instructions)
        case .cloud:
            guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                return LanguageModelSession(instructions: instructions)
            }
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: instructions
            )
        }
    }

    /// Which model a summary should be generated with.
    ///
    /// The first run of the day goes to the cloud; refinements that follow stay
    /// on-device. `hasCloudSummaryToday` is the whole decision — deliberately
    /// not the clock, because a day whose first glance is at 2pm still deserves
    /// the good model for the summary it starts from.
    static func forSummary(hasCloudSummaryToday: Bool) -> SummaryModel {
        hasCloudSummaryToday ? .local : .cloud
    }
}

extension SavedAISummary {
    /// The model that wrote this, or `nil` if the stored name is unrecognized.
    ///
    /// Lives here rather than on the model itself because the widget extension
    /// compiles `SavedAISummary` and has no `FoundationModels` dependency to
    /// resolve `SummaryModel` with. See the note on `generatedByRaw`.
    var generatedBy: SummaryModel? { SummaryModel(rawValue: generatedByRaw) }
}
