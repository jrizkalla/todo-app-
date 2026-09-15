//
//  AppMemory.swift
//  TODO
//
//  Created by John Rizkalla on 9/15/26.
//

import Foundation
import SwiftData

/// What the assistant has learned about the user across days.
///
/// One row, not one per fact: the memory is a document the user can open and
/// edit in Settings, and a pile of rows would have to be flattened into prose
/// every time it was shown or prompted with. Keeping it as text means what the
/// model reads and what the user edits are the same thing.
///
/// Every attribute carries a default because this shares the CloudKit-mirrored
/// store with everything else — see `SavedAISummary` for the same constraint.
/// `ModelTests.schemaIsCloudKitCompatible` enforces it.
@Model
final class AppMemory {
    /// Fixed so the row can be found without a sort: there is only ever one.
    var uuid: UUID = AppMemory.singletonID

    /// The memory itself, one fact per line.
    ///
    /// Lines rather than free prose because that is the shape the model is
    /// asked to emit and the shape compaction reduces back down to — and it is
    /// what makes the Settings editor legible enough to prune by hand.
    var text: String = ""

    /// When a fact was last added or compacted, shown in Settings.
    var updatedAt: Date = Date()

    /// When this was last compacted, which paces the next pass.
    ///
    /// Distinct from `updatedAt`: adding a fact moves that one and must not
    /// look like a compaction, or the file would never be compacted again.
    var compactedAt: Date?

    /// The line count at the last compaction.
    ///
    /// Compaction is worth running again once the file has grown meaningfully
    /// past what it was reduced to, which this is what makes measurable.
    var compactedLineCount: Int = 0

    static let singletonID = UUID(uuidString: "5E3A9C2E-1B6D-4F3A-9C1E-7D2A4B8F6C05")!

    init(text: String = "") {
        self.uuid = Self.singletonID
        self.text = text
        self.updatedAt = Date()
    }
}

extension AppMemory {

    /// The remembered facts, one per line, blanks dropped.
    var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// How many facts are held. What the compaction threshold is measured in.
    var lineCount: Int { lines.count }

    /// Past this many lines the file is long enough to be worth compacting.
    ///
    /// Chosen to be comfortably more than a day's worth of observations: the
    /// point is to catch a memory that has accumulated over weeks, not to
    /// re-summarize one that just picked up its third fact.
    static let compactionThreshold = 40

    /// Compact once the file has grown by half again since the last pass.
    ///
    /// Relative rather than absolute so a memory that legitimately settles at
    /// 60 lines is not re-compacted every single day for no gain.
    static let regrowthFactor = 1.5

    /// Whether the file has grown enough to be worth another pass.
    var needsCompaction: Bool {
        let count = lineCount
        guard count > Self.compactionThreshold else { return false }
        guard compactedAt != nil else { return true }
        return Double(count) >= Double(compactedLineCount) * Self.regrowthFactor
    }
}
