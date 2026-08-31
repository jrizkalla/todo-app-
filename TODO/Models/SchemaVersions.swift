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
    /// Both entities that have since changed shape are frozen copies.
    ///
    /// `Todo` moved in V3 (recurrence) and `SavedAISummary` in V2 (the prompt
    /// fingerprint), so naming the live classes here would make this version
    /// hash like the current one and silently disable both stages.
    static var models: [any PersistentModel.Type] {
        [SchemaV2.Todo.self, SchemaV2.Space.self, SchemaV2.Reminder.self, SavedAISummary.self]
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

    /// `Todo`, `Space`, and `Reminder` are *frozen copies*.
    ///
    /// `Todo` has to be frozen for the reason `SchemaV1` freezes
    /// `SavedAISummary`: V3 adds columns to the live `Todo`, and if both
    /// versions named the live class they would hash identically, the V2→V3
    /// stage would never fire, and the migration would be dead code that still
    /// failed on a real store.
    ///
    /// `Space` and `Reminder` come along not because their shape changed — it
    /// did not — but because they are *related to* `Todo`. A relationship's
    /// inverse is resolved by key path, so the live `Space.todos`, declared as
    /// `inverse: \Todo.space`, points at the live `Todo` and not at the copy.
    /// Pairing the frozen `Todo` with the live `Space` traps at schema
    /// construction with "Inverse Relationship does not exist". A version has to
    /// be internally consistent: every model in it referring only to other
    /// models in it.
    ///
    /// `SavedAISummary` stands apart precisely because it relates to nothing,
    /// and it reached its current shape at V2, so it stays the live class.
    static var models: [any PersistentModel.Type] {
        [SchemaV2.Todo.self, SchemaV2.Space.self, SchemaV2.Reminder.self, SavedAISummary.self]
    }

    /// `Todo` as it existed before recurrence.
    ///
    /// Nested so the Swift *class name* stays `Todo`, which is what CoreData
    /// derives the entity name from — the same trick, and the same reason, as
    /// `SchemaV1.SavedAISummary`.
    ///
    /// Only the *stored* shape reaches a version hash, so these copies carry the
    /// columns and relationships and none of the behaviour. Keeping them that
    /// way is deliberate: they describe bytes already on disk, not a working
    /// model, and must not drift toward the live classes.
    @Model
    final class Todo {
        var uuid: UUID = UUID()
        var title: String = ""
        var notes: String = ""
        var notesSummary: String = ""
        var stateRaw: String = CompletionState.open.rawValue
        var bucketRaw: String = Bucket.inbox.rawValue
        var assignedDate: Date?
        var assignedHasTime: Bool = false
        var duration: TimeInterval?
        var dueDate: Date?
        var dueHasTime: Bool = false
        var isProject: Bool = false
        var colorHex: String?
        var importedFromReminders: Bool = false
        var sourceReminderID: String?
        var sortIndex: Int = 0
        var isNew: Bool = false
        var lastViewedPlacement: String?
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var resolvedAt: Date?

        var space: SchemaV2.Space?
        var parent: SchemaV2.Todo?

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.Todo.parent)
        var subtasks: [SchemaV2.Todo]? = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.Reminder.todo)
        var reminders: [SchemaV2.Reminder]? = []

        init() {}
    }

    /// `Space` at V2 — unchanged in shape, frozen so the version is closed over
    /// its own `Todo`.
    @Model
    final class Space {
        var uuid: UUID = UUID()
        var name: String = ""
        var symbolName: String = "square.stack"
        var colorHex: String = Theme.Palette.defaultSpaceColor
        var sortIndex: Int = 0
        var createdAt: Date = Date()
        var isHiddenByFocus: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.Todo.space)
        var todos: [SchemaV2.Todo]? = []

        init() {}
    }

    /// `Reminder` at V2 — likewise unchanged, and likewise frozen.
    @Model
    final class Reminder {
        var uuid: UUID = UUID()
        var kindRaw: String = ReminderKind.dateTime.rawValue
        var fireDate: Date?
        var latitude: Double?
        var longitude: Double?
        var radius: Double = 100
        var placeName: String?
        var triggerRaw: String = LocationTrigger.onArrival.rawValue
        var isActive: Bool = true
        var createdAt: Date = Date()

        var todo: SchemaV2.Todo?

        init() {}
    }
}

/// `Todo` gains the recurrence columns.
///
/// Every added column is optional, which is what makes this a *lightweight*
/// migration rather than the custom stage V1→V2 needed. Existing rows simply
/// have no recurrence, which is the correct reading: a to-do that predates the
/// feature does not repeat.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    /// Frozen copies, for the reason `SchemaV2` spells out at length: V4 adds a
    /// column to the live `Todo`, and naming the live classes in both versions
    /// would make them hash identically, so the V3→V4 stage would never fire.
    ///
    /// `Space` and `Reminder` come along because they are related to `Todo` and
    /// a version has to be closed over its own models — pairing a frozen `Todo`
    /// with the live `Space` traps with "Inverse Relationship does not exist".
    static var models: [any PersistentModel.Type] {
        [SchemaV3.Todo.self, SchemaV3.Space.self, SchemaV3.Reminder.self, SavedAISummary.self]
    }

    /// `Todo` as it existed before week scheduling — V2's columns plus
    /// recurrence.
    ///
    /// Nested so the Swift class name stays `Todo`, which is what CoreData
    /// derives the entity name from. Stored shape only; see `SchemaV2.Todo`.
    @Model
    final class Todo {
        var uuid: UUID = UUID()
        var title: String = ""
        var notes: String = ""
        var notesSummary: String = ""
        var stateRaw: String = CompletionState.open.rawValue
        var bucketRaw: String = Bucket.inbox.rawValue
        var assignedDate: Date?
        var assignedHasTime: Bool = false
        var duration: TimeInterval?
        var dueDate: Date?
        var dueHasTime: Bool = false
        var isProject: Bool = false
        var colorHex: String?
        var importedFromReminders: Bool = false
        var sourceReminderID: String?
        var sortIndex: Int = 0

        var recurrenceModeRaw: String?
        var recurrenceFrequencyRaw: String?
        var recurrenceInterval: Int?
        var recurrenceWeekdaysRaw: String?
        var recurrenceDayOfMonth: Int?
        var recurrenceTimeOfDayMinutes: Int?
        var recurrenceEndDate: Date?
        var recurrenceStatusRaw: String?
        var recurrenceNextDate: Date?

        @Relationship(deleteRule: .nullify)
        var recurrenceTemplate: SchemaV3.Todo?

        var isNew: Bool = false
        var lastViewedPlacement: String?
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var resolvedAt: Date?

        var space: SchemaV3.Space?
        var parent: SchemaV3.Todo?

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.Todo.parent)
        var subtasks: [SchemaV3.Todo]? = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.Reminder.todo)
        var reminders: [SchemaV3.Reminder]? = []

        @Relationship(deleteRule: .nullify, inverse: \SchemaV3.Todo.recurrenceTemplate)
        var recurrenceInstances: [SchemaV3.Todo]? = []

        init() {}
    }

    /// `Space` at V3 — unchanged in shape, frozen so the version is closed over
    /// its own `Todo`.
    @Model
    final class Space {
        var uuid: UUID = UUID()
        var name: String = ""
        var symbolName: String = "square.stack"
        var colorHex: String = Theme.Palette.defaultSpaceColor
        var sortIndex: Int = 0
        var createdAt: Date = Date()
        var isHiddenByFocus: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.Todo.space)
        var todos: [SchemaV3.Todo]? = []

        init() {}
    }

    /// `Reminder` at V3 — likewise unchanged, and likewise frozen.
    @Model
    final class Reminder {
        var uuid: UUID = UUID()
        var kindRaw: String = ReminderKind.dateTime.rawValue
        var fireDate: Date?
        var latitude: Double?
        var longitude: Double?
        var radius: Double = 100
        var placeName: String?
        var triggerRaw: String = LocationTrigger.onArrival.rawValue
        var isActive: Bool = true
        var createdAt: Date = Date()

        var todo: SchemaV3.Todo?

        init() {}
    }
}

/// The current shape: `Todo` gains `weekAnchor`.
enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    /// The live models, deliberately — the newest version has to *be* the
    /// current schema, or the store will not open. See the note in `SchemaV2`
    /// about why freezing a copy here would be actively harmful.
    static var models: [any PersistentModel.Type] {
        [Todo.self, Space.self, Reminder.self, SavedAISummary.self]
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self]
    }

    static var stages: [MigrationStage] { [v1ToV2, v2ToV3, v3ToV4] }

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

    /// Adding recurrence to `Todo`.
    ///
    /// Lightweight, unlike the stage above: every new column is optional, so
    /// CoreData can add them to existing rows without a value and without being
    /// told what to put there. A to-do that predates the feature simply does
    /// not recur, which needs no backfill to express.
    ///
    /// The stage still has to be *declared* even though it does nothing —
    /// omitting it leaves V3 unreachable from V2 and the store fails to open
    /// with "Cannot use staged migration with an unknown model version".
    static let v2ToV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )

    /// Adding `weekAnchor` to `Todo`.
    ///
    /// Lightweight for the same reason V2→V3 is: the one added column is
    /// optional, and nil is the right reading for every row that predates the
    /// feature — a to-do written before week scheduling existed was not
    /// scheduled for a week.
    ///
    /// Declared even though it does nothing, because omitting it leaves V4
    /// unreachable from V3 and the store fails to open with "Cannot use staged
    /// migration with an unknown model version".
    static let v3ToV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )
}
