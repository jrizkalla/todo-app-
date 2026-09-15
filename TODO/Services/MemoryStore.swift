//
//  MemoryStore.swift
//  TODO
//
//  Created by John Rizkalla on 9/15/26.
//

import Foundation
import OSLog
import SwiftData

/// Reads and writes the single `AppMemory` row.
///
/// Wrapped in a store rather than queried inline because three different places
/// need it — the summary, the chat, and Settings — and all three have to agree
/// about the row being a singleton. Creating it lazily here is what makes that
/// true: nothing else is allowed to insert one.
@MainActor
struct MemoryStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The memory row, or `nil` if nothing has been remembered yet.
    ///
    /// Reading does not create the row: a user who never turns memory on should
    /// not accumulate an empty record that syncs to their other devices.
    func fetch() -> AppMemory? {
        let id = AppMemory.singletonID
        let descriptor = FetchDescriptor<AppMemory>(
            predicate: #Predicate { $0.uuid == id }
        )
        return try? context.fetch(descriptor).first
    }

    /// The memory row, created empty if it does not exist yet.
    func fetchOrCreate() -> AppMemory {
        if let existing = fetch() { return existing }
        let memory = AppMemory()
        context.insert(memory)
        return memory
    }

    /// The remembered text to put in front of a model, or `nil` for none.
    ///
    /// `nil` rather than an empty string so callers can leave the section out
    /// of the prompt entirely — an empty "here is what you know" heading reads
    /// to the model as though it had been told the user has no history.
    func promptText() -> String? {
        guard let memory = fetch() else { return nil }
        let trimmed = memory.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Add newly observed facts, skipping ones already held.
    ///
    /// De-duplicated case-insensitively because the model will happily emit
    /// "Works from home on Fridays" one day and "works from home on fridays"
    /// the next, and a memory file that accumulates both is one the user has to
    /// clean up by hand.
    @discardableResult
    func remember(_ facts: [String]) -> Int {
        // The file is one fact per line, so each candidate is flattened to a
        // single line before it goes in. A multi-line fact would otherwise
        // become several lines that the de-duplication above never sees as a
        // unit, and a fact of just "\n" would write a blank line the user then
        // finds as an unexplained gap in the Settings editor — note that a
        // `.whitespaces` trim does not remove newlines, only `.whitespacesAndNewlines`.
        let candidates = facts
            .flatMap { $0.split(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return 0 }

        let memory = fetchOrCreate()
        var seen = Set(memory.lines.map { $0.lowercased() })

        var added: [String] = []
        for fact in candidates where seen.insert(fact.lowercased()).inserted {
            added.append(fact)
        }
        guard !added.isEmpty else { return 0 }

        let existing = memory.text.trimmingCharacters(in: .whitespacesAndNewlines)
        memory.text = existing.isEmpty
            ? added.joined(separator: "\n")
            : existing + "\n" + added.joined(separator: "\n")
        memory.updatedAt = Date()
        save()
        return added.count
    }

    /// Replace the whole file — used by the Settings editor and by compaction.
    func replace(with text: String) {
        let memory = fetchOrCreate()
        memory.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        memory.updatedAt = Date()
        save()
    }

    /// Record the result of a compaction pass.
    ///
    /// Separate from `replace` so only a real compaction moves the bookkeeping
    /// that paces the next one; a hand edit in Settings must not.
    func recordCompaction(text: String) {
        let memory = fetchOrCreate()
        memory.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        memory.updatedAt = Date()
        memory.compactedAt = Date()
        memory.compactedLineCount = memory.lineCount
        save()
    }

    /// Forget everything. The Settings "Clear" button.
    func clear() {
        guard let memory = fetch() else { return }
        context.delete(memory)
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.data.error("Memory save failed: \(error, privacy: .public)")
        }
    }
}

// MARK: - Extraction

extension MemoryStore {

    /// The tag the model wraps each durable fact in.
    ///
    /// A tag rather than a JSON field because memory is emitted by both the
    /// summary (which returns JSON) and the chat (which returns prose), and a
    /// single marker means one parser serves both.
    static let openTag = "<memory>"
    static let closeTag = "</memory>"

    /// Pull tagged facts out of a model response.
    ///
    /// Returns the facts and the text with the tags removed, because the user
    /// must never see the bookkeeping: a chat reply ending in a stray
    /// `<memory>` block would read as the assistant talking to itself.
    static func extract(from response: String) -> (facts: [String], cleaned: String) {
        guard response.contains(openTag) else { return ([], response) }

        var facts: [String] = []
        var cleaned = ""
        var rest = Substring(response)

        while let open = rest.range(of: openTag) {
            cleaned += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]

            guard let close = afterOpen.range(of: closeTag) else {
                // An unterminated tag: treat the remainder as the fact rather
                // than leaking a half-open tag into what the user reads.
                let fact = afterOpen.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fact.isEmpty { facts.append(contentsOf: splitFacts(fact)) }
                return (facts, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let fact = afterOpen[afterOpen.startIndex..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fact.isEmpty { facts.append(contentsOf: splitFacts(fact)) }
            rest = afterOpen[close.upperBound...]
        }

        cleaned += rest
        return (facts, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One tag may hold several facts, one per line.
    ///
    /// Leading bullets are stripped: the model is asked for bare lines but
    /// reliably reaches for "- " anyway, and a file of half-bulleted lines
    /// breaks the de-duplication that keeps it from growing.
    private static func splitFacts(_ block: String) -> [String] {
        block.split(separator: "\n")
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                for bullet in ["- ", "* ", "• "] where text.hasPrefix(bullet) {
                    text = String(text.dropFirst(bullet.count))
                    break
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}
