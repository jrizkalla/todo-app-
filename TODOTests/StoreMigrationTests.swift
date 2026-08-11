import Testing
import Foundation
import SwiftData
import CoreData
@testable import TODO

/// Opening a store written by the previous schema version.
///
/// These use a real on-disk store rather than an in-memory one: an in-memory
/// container is created empty every time, so it never migrates anything and
/// would pass no matter how broken the plan was. The failure this guards
/// against — a summary row that predates the prompt fingerprint blocking the
/// open — only reproduces against a file.
@MainActor
struct StoreMigrationTests {

    /// A scratch directory that cleans itself up.
    private func withTemporaryStore(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appending(path: "TODO.store"))
    }

    /// Open a store at `url` under a specific schema version.
    private func container(
        at url: URL,
        schema: Schema,
        plan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema,
            migrationPlan: plan,
            configurations: [configuration]
        )
    }

    /// The regression this whole plan exists for.
    ///
    /// A V1 store containing a saved summary must open under V2. Before the
    /// migration plan this threw NSCocoaErrorDomain 134110, "missing attribute
    /// values on mandatory destination attribute", and took the user's todos
    /// with it — the store simply would not open.
    @Test func v1StoreWithASavedSummaryOpensUnderV2() throws {
        try withTemporaryStore { url in
            // Write a V1 store: todos, a space, and the summary that blocks it.
            do {
                let v1 = try container(at: url, schema: Schema(SchemaV1.models))
                let context = ModelContext(v1)
                let space = Space(name: "Work", symbolName: "briefcase")
                context.insert(space)
                for title in ["Alpha", "Beta", "Gamma"] {
                    context.insert(Todo(title: title))
                }
                context.insert(SavedAISummary(summary: .init(
                    quickSummary: "A busy day",
                    detailedSummary: ["Something to do"]
                )))
                try context.save()
            }

            // Reopen under V2 through the plan.
            let v2 = try container(
                at: url,
                schema: Schema(SchemaV2.models),
                plan: AppMigrationPlan.self
            )
            let context = ModelContext(v2)

            // The user's data is what matters: it must all still be there.
            let todos = try context.fetch(FetchDescriptor<Todo>())
            #expect(Set(todos.map(\.title)) == ["Alpha", "Beta", "Gamma"])

            let spaces = try context.fetch(FetchDescriptor<Space>())
            #expect(spaces.map(\.name) == ["Work"])
        }
    }

    /// The cached summary is dropped rather than carried across.
    ///
    /// It is regenerated on the next launch, so this is the one piece of data
    /// the migration is allowed to discard — and it is why the mandatory
    /// fingerprint columns have no rows left to fail on.
    @Test func theCachedSummaryIsDiscardedByTheMigration() throws {
        try withTemporaryStore { url in
            do {
                let v1 = try container(at: url, schema: Schema(SchemaV1.models))
                let context = ModelContext(v1)
                context.insert(SavedAISummary(summary: .init(quickSummary: "Stale")))
                try context.save()
            }

            let v2 = try container(
                at: url,
                schema: Schema(SchemaV2.models),
                plan: AppMigrationPlan.self
            )
            let summaries = try ModelContext(v2).fetch(FetchDescriptor<SavedAISummary>())
            #expect(summaries.isEmpty)
        }
    }

    /// A summary written *after* the migration keeps its fingerprint, so the
    /// reuse check still works on the upgraded store.
    @Test func aFingerprintSurvivesAWriteAndReopenUnderV2() throws {
        try withTemporaryStore { url in
            var fingerprint = SummaryFingerprint()
            fingerprint.instructions = "morning"
            fingerprint.todos = ["scheduled|todo|Alpha"]

            do {
                let v2 = try container(
                    at: url,
                    schema: Schema(SchemaV2.models),
                    plan: AppMigrationPlan.self
                )
                let context = ModelContext(v2)
                context.insert(SavedAISummary(
                    summary: .init(quickSummary: "Done"),
                    fingerprint: fingerprint
                ))
                try context.save()
            }

            let reopened = try container(
                at: url,
                schema: Schema(SchemaV2.models),
                plan: AppMigrationPlan.self
            )
            let saved = try ModelContext(reopened).fetch(FetchDescriptor<SavedAISummary>())
            #expect(saved.count == 1)
            #expect(saved.first?.fingerprint.matches(fingerprint) == true)
        }
    }

    /// `SchemaV1` must keep describing the store that actually shipped.
    ///
    /// These hashes were read out of the real store's `Z_METADATA`, which is how
    /// the V1 mismatch was found in the first place: CoreData rejected the open
    /// with "Cannot use staged migration with an unknown model version" because
    /// the frozen copy had been renamed and so hashed differently.
    ///
    /// Pinned to literals on purpose. Every other check here compares the code
    /// against itself and can be satisfied by editing both sides; these bytes
    /// exist on disk in stores already out there and cannot be edited at all.
    /// If this fails, `SchemaV1` has been altered and no longer describes the
    /// data it is supposed to migrate — fix V1 rather than updating the
    /// expectation.
    @Test func theV1SchemaStillMatchesTheShippedStore() throws {
        let shipped = [
            "Reminder": "bo1V6iOcTagsXmu8iPzofj6q0RZj0O/mX3xP+JuI6YU=",
            "SavedAISummary": "BtSxE+MqcEda6QNoIdwFsUvO0aB0AWfRnlZvMPk0ZZw=",
            "Space": "8oWOnQO+mbMbAEFMpLG4wceRP/HWxQV3lYcxCNin6P0=",
            "Todo": "66U5IP1pAhlZ8r8/ahXxHIeqRm8ybhYVWgf4kpEQ9CI=",
        ]

        guard let v1 = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models) else {
            Issue.record("Could not build a managed object model for SchemaV1")
            return
        }

        let actual = v1.entityVersionHashesByName.mapValues { $0.base64EncodedString() }
        #expect(actual == shipped)
    }

    /// The newest version in the plan must be the live schema.
    ///
    /// Note this cannot fail while `SchemaV2.models` lists the live models —
    /// both sides move together by construction, and freezing a copy to break
    /// that is what makes two same-named `@Model` classes collide at runtime.
    /// It earns its place at the *next* version: once a V3 exists with its own
    /// frozen copy, this is what catches that copy falling behind.
    @Test func theLatestSchemaVersionMatchesTheLiveModels() throws {
        guard let latest = AppMigrationPlan.schemas.last else {
            Issue.record("The migration plan has no schema versions")
            return
        }
        guard
            let live = NSManagedObjectModel.makeManagedObjectModel(for: AppSchema.models),
            let newest = NSManagedObjectModel.makeManagedObjectModel(for: latest.models)
        else {
            Issue.record("Could not build a managed object model")
            return
        }

        #expect(
            live.entityVersionHashesByName == newest.entityVersionHashesByName,
            """
            AppSchema.models no longer matches the newest version in \
            AppMigrationPlan. Add a new VersionedSchema and a MigrationStage \
            for the change.
            """
        )
    }

    /// Every entity in the store's current schema must also exist in V1 under
    /// the same name.
    ///
    /// Renaming the frozen copy is the mistake that produced "Cannot use staged
    /// migration with an unknown model version" on the real store: CoreData
    /// derives the entity name from the Swift class name, so a renamed copy
    /// describes a different entity and matches nothing on disk.
    @Test func theFrozenV1EntityNamesMatchTheLiveOnes() throws {
        let v1 = Set(Schema(SchemaV1.models).entities.map(\.name))
        let live = Set(Schema(AppSchema.models).entities.map(\.name))
        #expect(v1 == live)
    }

    /// A store already at V2 opens without the plan doing anything to it.
    @Test func anAlreadyMigratedStoreOpensUnchanged() throws {
        try withTemporaryStore { url in
            do {
                let v2 = try container(
                    at: url,
                    schema: Schema(SchemaV2.models),
                    plan: AppMigrationPlan.self
                )
                let context = ModelContext(v2)
                context.insert(Todo(title: "Kept"))
                context.insert(SavedAISummary(summary: .init(quickSummary: "Kept too")))
                try context.save()
            }

            let reopened = try container(
                at: url,
                schema: Schema(SchemaV2.models),
                plan: AppMigrationPlan.self
            )
            let context = ModelContext(reopened)
            #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.title) == ["Kept"])
            // Not dropped this time: the stage only runs crossing V1 -> V2.
            #expect(try context.fetch(FetchDescriptor<SavedAISummary>()).count == 1)
        }
    }
}
