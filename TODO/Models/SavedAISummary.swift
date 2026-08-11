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

    init(summary: AISummary) {
        uuid = UUID()
        generatedOn = Date()
        self.summary = summary
    }
}
