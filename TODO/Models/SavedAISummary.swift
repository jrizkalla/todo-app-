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


@Model
final class SavedAISummary {
    var uuid: UUID
    var generatedOn: Date
    
    var summary: AISummary
    
    init(summary: AISummary) {
        uuid = UUID()
        generatedOn = Date()
        self.summary = summary
    }
}
