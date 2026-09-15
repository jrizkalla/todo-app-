import Testing
import Foundation
import SwiftData
@testable import TODO

/// Pulling remembered facts out of what the model wrote.
///
/// The parser is the seam between a model that will format things however it
/// likes and a file the user reads and edits, so these are mostly about it
/// being unbothered by the shapes the model actually produces.
@MainActor
struct MemoryExtractionTests {

    private func tagged(_ body: String) -> String {
        "\(MemoryStore.openTag)\n\(body)\n\(MemoryStore.closeTag)"
    }

    /// The common case: JSON, then a memory block after it.
    @Test func pullsFactsOutAndLeavesTheBody() {
        let response = """
        {"quickSummary": "Busy day."}
        \(tagged("Works from home on Fridays."))
        """
        let (facts, cleaned) = MemoryStore.extract(from: response)

        #expect(facts == ["Works from home on Fridays."])
        #expect(cleaned == #"{"quickSummary": "Busy day."}"#)
    }

    /// The normal case is no memory at all, and it must not disturb the body.
    @Test func aResponseWithNoMemoryIsUntouched() {
        let response = #"{"quickSummary": "Busy day."}"#
        let (facts, cleaned) = MemoryStore.extract(from: response)

        #expect(facts.isEmpty)
        #expect(cleaned == response)
    }

    @Test func severalFactsInOneBlockAreSplitByLine() {
        let (facts, _) = MemoryStore.extract(from: tagged("""
        Commutes by bike.
        Prefers mornings for deep work.
        """))
        #expect(facts == ["Commutes by bike.", "Prefers mornings for deep work."])
    }

    /// The instructions ask for bare lines; the model reaches for bullets
    /// anyway, and a half-bulleted file breaks de-duplication.
    @Test func bulletsAreStripped() {
        let (facts, _) = MemoryStore.extract(from: tagged("""
        - Commutes by bike.
        * Prefers mornings.
        • Dislikes late meetings.
        """))
        #expect(facts == [
            "Commutes by bike.",
            "Prefers mornings.",
            "Dislikes late meetings.",
        ])
    }

    @Test func blankLinesInABlockAreDropped() {
        let (facts, _) = MemoryStore.extract(from: tagged("""
        Commutes by bike.

        Prefers mornings.
        """))
        #expect(facts.count == 2)
    }

    /// Prose on both sides of the block, as the chat produces.
    @Test func factsAreLiftedOutOfTheMiddleOfProse() {
        let response = """
        You have three things left today.
        \(tagged("Has a standing Thursday call."))
        Start with the overdue one.
        """
        let (facts, cleaned) = MemoryStore.extract(from: response)

        #expect(facts == ["Has a standing Thursday call."])
        #expect(cleaned.contains("three things left"))
        #expect(cleaned.contains("Start with the overdue one."))
        #expect(!cleaned.contains(MemoryStore.openTag))
    }

    @Test func severalBlocksAreAllCollected() {
        let response = tagged("One.") + "\nmiddle\n" + tagged("Two.")
        let (facts, cleaned) = MemoryStore.extract(from: response)

        #expect(facts == ["One.", "Two."])
        #expect(cleaned == "middle")
    }

    /// A truncated response must not leak a dangling tag into what is shown.
    @Test func anUnterminatedTagStillYieldsItsFact() {
        let response = "Here you go.\n\(MemoryStore.openTag)\nRuns in the evenings."
        let (facts, cleaned) = MemoryStore.extract(from: response)

        #expect(facts == ["Runs in the evenings."])
        #expect(cleaned == "Here you go.")
        #expect(!cleaned.contains(MemoryStore.openTag))
    }

    /// An empty block is the model following the letter of the instruction and
    /// not the point of it. It must not write a blank line to the file.
    @Test func anEmptyBlockRemembersNothing() {
        let (facts, _) = MemoryStore.extract(from: tagged("   "))
        #expect(facts.isEmpty)
    }
}

/// Reading and writing the memory row.
@MainActor
struct MemoryStoreTests {

    private func store() throws -> MemoryStore {
        let container = try ModelContainer.appContainer(inMemory: true, cloudKit: false)
        return MemoryStore(context: ModelContext(container))
    }

    /// Reading must not create the row: someone who never turns memory on
    /// should not end up syncing an empty record to their other devices.
    @Test func fetchingDoesNotCreateTheRow() throws {
        let store = try store()
        #expect(store.fetch() == nil)
        #expect(store.promptText() == nil)
    }

    @Test func rememberingCreatesTheRowAndHoldsTheFact() throws {
        let store = try store()
        store.remember(["Commutes by bike."])

        #expect(store.fetch()?.lines == ["Commutes by bike."])
        #expect(store.promptText() == "Commutes by bike.")
    }

    @Test func factsAccumulateAcrossCalls() throws {
        let store = try store()
        store.remember(["One."])
        store.remember(["Two."])

        #expect(store.fetch()?.lines == ["One.", "Two."])
    }

    /// The model re-states what it already knows, so this is the rule that
    /// keeps the file from doubling every day.
    @Test func aFactAlreadyHeldIsNotAddedAgain() throws {
        let store = try store()
        store.remember(["Commutes by bike."])
        let added = store.remember(["Commutes by bike."])

        #expect(added == 0)
        #expect(store.fetch()?.lines.count == 1)
    }

    /// Case is the difference the model is most likely to produce between days.
    @Test func deduplicationIgnoresCase() throws {
        let store = try store()
        store.remember(["Commutes by bike."])
        store.remember(["commutes by BIKE."])

        #expect(store.fetch()?.lines.count == 1)
    }

    @Test func duplicatesWithinOneCallCollapse() throws {
        let store = try store()
        let added = store.remember(["One.", "One.", "Two."])

        #expect(added == 2)
        #expect(store.fetch()?.lines.count == 2)
    }

    @Test func blankFactsAreIgnored() throws {
        let store = try store()
        let added = store.remember(["", "   ", "\n"])

        #expect(added == 0)
        #expect(store.fetch() == nil)
    }

    @Test func replaceOverwritesTheWholeFile() throws {
        let store = try store()
        store.remember(["One.", "Two."])
        store.replace(with: "Only this.")

        #expect(store.fetch()?.lines == ["Only this."])
    }

    @Test func clearRemovesTheRow() throws {
        let store = try store()
        store.remember(["One."])
        store.clear()

        #expect(store.fetch() == nil)
    }

    /// A file of only whitespace must read as nothing to say, not as a heading
    /// with an empty list under it.
    @Test func awhitespaceOnlyFileIsNotPrompted() throws {
        let store = try store()
        store.replace(with: "   \n  \n")

        #expect(store.promptText() == nil)
    }

    // MARK: Compaction pacing

    @Test func aShortFileIsNotWorthCompacting() throws {
        let store = try store()
        store.remember((1...5).map { "Fact \($0)." })

        #expect(store.fetch()?.needsCompaction == false)
    }

    @Test func aLongFileThatHasNeverBeenCompactedIs() throws {
        let store = try store()
        store.remember((1...(AppMemory.compactionThreshold + 1)).map { "Fact \($0)." })

        #expect(store.fetch()?.needsCompaction == true)
    }

    /// Having just been compacted, it must not immediately want compacting
    /// again — otherwise every generation would spend a model call on it.
    @Test func compactingClearsTheNeed() throws {
        let store = try store()
        store.remember((1...(AppMemory.compactionThreshold + 1)).map { "Fact \($0)." })
        store.recordCompaction(
            text: (1...(AppMemory.compactionThreshold + 1)).map { "Fact \($0)." }
                .joined(separator: "\n")
        )

        #expect(store.fetch()?.needsCompaction == false)
    }

    /// And it must want compacting again once it has meaningfully regrown.
    @Test func regrowthPastTheFactorNeedsCompactingAgain() throws {
        let store = try store()
        let base = AppMemory.compactionThreshold + 1
        store.remember((1...base).map { "Fact \($0)." })
        store.recordCompaction(
            text: (1...base).map { "Fact \($0)." }.joined(separator: "\n")
        )

        let target = Int(Double(base) * AppMemory.regrowthFactor) + 1
        store.remember(((base + 1)...target).map { "Fact \($0)." })

        #expect(store.fetch()?.needsCompaction == true)
    }

    /// A hand edit in Settings is not a compaction, and must not reset the
    /// pacing — otherwise a user tidying the file would postpone the real pass.
    @Test func aHandEditDoesNotCountAsCompaction() throws {
        let store = try store()
        store.remember((1...(AppMemory.compactionThreshold + 1)).map { "Fact \($0)." })
        store.replace(with: (1...(AppMemory.compactionThreshold + 1))
            .map { "Fact \($0)." }
            .joined(separator: "\n"))

        #expect(store.fetch()?.compactedAt == nil)
        #expect(store.fetch()?.needsCompaction == true)
    }
}

/// The check that stands between a bad consolidation and a lost memory.
///
/// Compaction runs on the same small on-device model as everything else, and it
/// is the one call that can destroy what the assistant knows. These pin the
/// cases where its output must be thrown away rather than written back.
@MainActor
struct MemoryCompactionGuardTests {

    private func lines(_ count: Int) -> String {
        (1...count).map { "Fact \($0)." }.joined(separator: "\n")
    }

    /// The point of the exercise: a genuine consolidation is accepted.
    @Test func aModestConsolidationIsAccepted() {
        #expect(AISummaryService.isPlausibleCompaction(of: lines(40), into: lines(30)))
    }

    /// Nothing removed at all is fine — the file was already tidy.
    @Test func anUnchangedFileIsAccepted() {
        let text = lines(40)
        #expect(AISummaryService.isPlausibleCompaction(of: text, into: text))
    }

    /// The failure that matters: the model summarizes instead of consolidating,
    /// and forty facts become one sentence.
    @Test func aCollapseIntoASentenceIsRejected() {
        #expect(!AISummaryService.isPlausibleCompaction(
            of: lines(40),
            into: "The user has a busy and varied schedule."
        ))
    }

    /// An empty result is a failure, never an instruction to forget everything.
    @Test func anEmptyResultIsRejected() {
        #expect(!AISummaryService.isPlausibleCompaction(of: lines(40), into: ""))
        #expect(!AISummaryService.isPlausibleCompaction(of: lines(40), into: "   \n  "))
    }

    /// Blank lines must not pad a collapse into looking acceptable.
    @Test func blankLinesDoNotCountTowardsTheFloor() {
        let padded = "One surviving fact.\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
        #expect(!AISummaryService.isPlausibleCompaction(of: lines(40), into: padded))
    }

    /// Exactly at the floor is allowed; a line below it is not.
    @Test func theFloorIsInclusive() {
        #expect(AISummaryService.isPlausibleCompaction(of: lines(40), into: lines(20)))
        #expect(!AISummaryService.isPlausibleCompaction(of: lines(40), into: lines(19)))
    }

    /// Nothing to judge against must not wedge the file permanently.
    @Test func anEmptyOriginalDoesNotBlockAResult() {
        #expect(AISummaryService.isPlausibleCompaction(of: "", into: "A fact."))
    }
}
