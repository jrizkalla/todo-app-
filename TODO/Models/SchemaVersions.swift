//
//  SchemaVersions.swift
//  TODO
//
//  Created by John Rizkalla on 8/11/26.
//

import Foundation
import SwiftData

/// The store's schema history, and the plan that walks a store from one version
/// to the next.
///
/// Until the AI summary grew a prompt fingerprint, every schema change had been
/// additive in a way SwiftData's implicit lightweight migration could infer on
/// its own, so there was no plan here at all. Adding `SummaryFingerprint` broke
/// that: `@Model` flattens a composite struct into one store attribute per
/// member, and a non-optional member becomes a *mandatory* column. Existing rows
/// have no value for it, so the store refused to open with
///
///     Cannot migrate store in-place: Validation error missing attribute values
///     on mandatory destination attribute (entity=SavedAISummary,
///     attribute=instructions)
///
/// A Swift-level default (`var instructions: String = ""`) does not help: it
/// applies when *Swift* constructs the value, not when CoreData migrates rows
/// that predate the column.
///
/// The fix is to say explicitly what the implicit migration could not infer.
/// `V1` is the shape already on disk and `V2` adds the fingerprint, with a
/// custom stage that fills it in for rows that predate it.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// `SavedAISummary` is a *frozen copy* of the old shape, not the live class.
    ///
    /// This is the part that is easy to get wrong: SwiftData decides whether a
    /// stage fires by comparing version hashes computed from the model types
    /// themselves. Listing the live `SavedAISummary` here would make V1 and V2
    /// hash identically, the stage would silently never run, and the migration
    /// would be dead code that still failed on a real store.
    ///
    /// Only the entity whose shape changed needs freezing; the other three are
    /// identical in both versions, so they stay shared rather than being
    /// duplicated into copies that would drift.
    static var models: [any PersistentModel.Type] {
        [Todo.self, Space.self, Reminder.self, SavedAISummary.self]
    }

    /// `SavedAISummary` as it existed before the prompt fingerprint.
    ///
    /// Nested so the Swift *class name* stays `SavedAISummary`, which is what
    /// CoreData derives the entity name from. An earlier attempt called this
    /// `SavedAISummaryV1` and the migration failed on a real store with
    /// "Cannot use staged migration with an unknown model version": the rename
    /// produced a different entity, so the store's existing `SavedAISummary`
    /// matched no version in the plan. The nested type keeps the name while
    /// staying a distinct type in Swift.
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
}

/// The current shape: `SavedAISummary` gains `fingerprint`.
enum SchemaV2: VersionedSchema {
    /// The store on disk records 1.0.0, so V1 keeps that identifier and this
    /// one moves past it. Stage selection is driven by the per-entity version
    /// hashes rather than these numbers, but they must still be ordered.
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// The live models, deliberately.
    ///
    /// The newest version has to *be* the current schema — that is what makes
    /// the store openable. Freezing a copy here was tried and is actively
    /// harmful: two `@Model` classes with the same name collide at runtime, and
    /// fetching a `SavedAISummary` then traps with "Failed to cast model".
    ///
    /// The cost is that `theLatestSchemaVersionMatchesTheLiveModels` cannot
    /// detect drift at *this* version, since both sides move together. What it
    /// does catch is the next change: adding a V3 whose frozen copy has fallen
    /// behind the live models. Until then, `theV1SchemaStillMatchesTheShippedStore`
    /// is the guard with teeth, because V1's hashes are pinned to bytes that
    /// already exist on disk and cannot be edited into agreement.
    static var models: [any PersistentModel.Type] {
        [Todo.self, Space.self, Reminder.self, SavedAISummary.self]
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    static var stages: [MigrationStage] { [v1ToV2] }

    /// Adding the prompt fingerprint to `SavedAISummary`.
    ///
    /// Custom rather than lightweight because the new mandatory columns have no
    /// value in existing rows. The cached summary is disposable — it is
    /// regenerated from the model whenever the day's inputs change — so rather
    /// than inventing a fingerprint that would falsely claim to describe the
    /// saved text, the stage drops the cached summaries and lets the next launch
    /// generate a fresh one.
    ///
    /// Deleting these rows costs the user nothing: a summary is a few sentences
    /// about today, not something they authored. Their to-dos, spaces, and
    /// reminders are untouched.
    ///
    /// The delete names the *V1* type deliberately. `willMigrate` runs while the
    /// store is still on the old schema, so asking for the V2 `SavedAISummary`
    /// there raises "executeRequest: entity not found" from inside
    /// `applyMigrationStage` and takes the open down with it.
    static let v1ToV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            try context.delete(model: SchemaV1.SavedAISummary.self)
            try context.save()
        },
        didMigrate: nil
    )
}
