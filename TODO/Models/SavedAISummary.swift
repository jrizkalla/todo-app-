//
//  AISummary.swift
//  TODO
//
//  Created by John Rizkalla on 8/9/26.
//

import Foundation
import SwiftData

struct AISummary: Codable {
    var quickSummary: String?
    var detailedSummary: [String] = []
}


/// The last generated summary, cached so reopening Today does not re-run the
/// model against an unchanged day.
///
/// Every attribute carries a default: CloudKit mirroring requires attributes to
/// be optional or defaulted, and this is in the same store as everything else.
/// `ModelTests.schemaIsCloudKitCompatible` is what enforces that.
@Model
final class SavedAISummary {
    var uuid: UUID = UUID()
    var generatedOn: Date = Date()

    var summary: AISummary = AISummary()

    /// What the prompt looked like when `summary` was generated.
    ///
    /// Defaulted to an empty fingerprint so a summary saved before this existed
    /// simply fails to match and is regenerated once, rather than needing a
    /// migration.
    var fingerprint: SummaryFingerprint = SummaryFingerprint()

    /// Which model wrote this, as a `SummaryModel` raw value.
    ///
    /// Stored so the next generation of the day can tell whether the cloud pass
    /// has already happened: the first summary is worth the good model, and the
    /// refinements after it are not.
    ///
    /// A bare `String`, and the `SummaryModel` bridge lives in the app target,
    /// because the widget extension compiles this file and must not be made to
    /// import `FoundationModels` to do it — the same reason `SummaryFingerprint`
    /// is split across two files.
    ///
    /// Defaulted to `"local"` so a summary saved before this existed is read as
    /// not yet having had its cloud pass — which at worst spends one cloud
    /// call, rather than withholding it for the rest of the day.
    var generatedByRaw: String = "local"

    init(
        summary: AISummary,
        fingerprint: SummaryFingerprint = SummaryFingerprint(),
        generatedByRaw: String = "local"
    ) {
        uuid = UUID()
        generatedOn = Date()
        self.summary = summary
        self.fingerprint = fingerprint
        self.generatedByRaw = generatedByRaw
    }
}
