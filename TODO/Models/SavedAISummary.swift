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

    init(summary: AISummary, fingerprint: SummaryFingerprint = SummaryFingerprint()) {
        uuid = UUID()
        generatedOn = Date()
        self.summary = summary
        self.fingerprint = fingerprint
    }
}
