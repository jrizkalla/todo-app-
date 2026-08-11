import Foundation
import OSLog
import Security
import SwiftData

/// The app's schema, in one place so the widget extension and the macOS CLI can
/// open the same store without duplicating the model list.
enum AppSchema {
    /// Every `@Model` in the app.
    ///
    /// A model missing from this list is not in the store's schema, so anything
    /// that queries or writes it fails at the CoreData layer rather than at
    /// compile time — persistent history hits "not a valid entity name" and
    /// takes the app down with it. Adding an `@Model` means adding it here.
    ///
    /// It also means teaching the archive about it — `ArchiveFormat.RecordKind`
    /// plus a writer and reader in `DatabaseExporter`/`DatabaseImporter` —
    /// or the new model is silently left out of every export.
    /// `DatabaseArchiveTests.everyModelHasAnArchiveRecordKind` catches the miss.
    static let models: [any PersistentModel.Type] = [
        Todo.self,
        Space.self,
        Reminder.self,
        SavedAISummary.self,
    ]

    static var schema: Schema { Schema(models) }

    /// App group holding the SwiftData store.
    ///
    /// A group container (rather than the app's private container) is what lets
    /// a future widget extension and CLI read the same database. Falls back to
    /// the default location when the group is unavailable, which is the case
    /// until the App Group capability is enabled for the bundle id.
    static let appGroupIdentifier = "group.com.johnrizkalla.app.TODO"

    /// CloudKit container backing sync.
    static let cloudKitContainerIdentifier = "iCloud.johnrizkalla.app.todo"

    /// Location of the shared SwiftData store, inside the app group.
    ///
    /// `nil` when the App Group capability is not provisioned for this build,
    /// in which case callers fall back to the app's private container. The
    /// widget has no fallback: without the group there is no shared store for
    /// it to read.
    static var storeURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "TODO.store")
    }
}

extension ModelContainer {
    /// Build the app's container.
    ///
    /// - Parameters:
    ///   - inMemory: Used by tests and previews so they never touch the store.
    ///   - cloudKit: Enables CloudKit mirroring. Disabled automatically when the
    ///     app group is unavailable, since mirroring needs a stable container.
    static func appContainer(
        inMemory: Bool = false,
        cloudKit: Bool = true
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration

        if inMemory {
            configuration = ModelConfiguration(
                schema: AppSchema.schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            // The container's Application Support directory may not exist yet on
            // a fresh install.
            ensureStoreDirectoryExists()

            let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = cloudKit
                ? .private(AppSchema.cloudKitContainerIdentifier)
                : .none

            // Prefer the group container so the widget opens the same store.
            // Falling back to the default location keeps the app working when
            // the App Group capability is not provisioned — the widget simply
            // has nothing to read, rather than the app failing to launch.
            if let groupURL = AppSchema.storeURL {
                migrateLegacyStoreIfNeeded(to: groupURL)

                configuration = ModelConfiguration(
                    schema: AppSchema.schema,
                    url: groupURL,
                    cloudKitDatabase: cloudKitDatabase
                )
            } else {
                AppLog.data.warning("App group unavailable; using the app's private store")
                configuration = ModelConfiguration(
                    schema: AppSchema.schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: cloudKitDatabase
                )
            }
        }

        // The migration plan is what carries a store from V1 to V2; without it
        // SwiftData attempts an implicit lightweight migration, which cannot
        // add SavedAISummary's mandatory fingerprint columns to existing rows
        // and fails the open outright. See `AppMigrationPlan`.
        return try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// True when the process is hosting an XCTest/Swift Testing bundle.
    ///
    /// The unit tests run inside the app as their test host, so `@main` executes
    /// first. Tests build their own in-memory containers and must not pay for —
    /// or crash on — CloudKit setup, which is unavailable in that environment.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Whether the app is built with CloudKit sync enabled.
    ///
    /// Requesting mirroring without the entitlement fails at runtime with "your
    /// process must have a com.apple.developer.icloud-services entitlement" —
    /// the store still opens, but sync silently never happens, which is worse
    /// than not asking.
    ///
    /// `SecTask` is unavailable to Swift on iOS, so rather than inspect the
    /// signature at runtime this is a compile-time switch that must be flipped
    /// together with the entitlement file. It is off because a free Apple team
    /// cannot provision iCloud; see `TODO.entitlements` for how to enable both.
    static let hasCloudKitEntitlement = true

    /// Whether CloudKit mirroring can be requested safely.
    ///
    /// This has to be decided *before* building the container. When the
    /// container identifier is not provisioned — the entitlement is missing, or
    /// the container has not been created in the developer portal — CoreData's
    /// mirroring delegate fails on a background queue after `ModelContainer`
    /// init has already returned, so a `do`/`catch` around init cannot recover.
    /// Checking up front is what keeps that failure from happening at all.
    static var canUseCloudKit: Bool {
        guard !isRunningTests else { return false }

        guard hasCloudKitEntitlement else {
            AppLog.data.info("No CloudKit entitlement; using a local store")
            return false
        }

        // Mirroring also needs a signed-in account to sync to.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            AppLog.data.info("No iCloud account signed in; using a local store")
            return false
        }

        return true
    }

    /// Move a pre-app-group store into the group container.
    ///
    /// Before the widget existed the store lived in the app's private
    /// Application Support directory. Pointing at the group container without
    /// this would silently present an empty database to anyone upgrading, which
    /// reads as total data loss.
    ///
    /// Copies rather than moves, and only when the destination is absent, so a
    /// failure part-way leaves the original intact to try again next launch.
    private static func migrateLegacyStoreIfNeeded(to groupURL: URL) {
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: groupURL.path) else { return }

        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        // SwiftData's implicit store name, plus the SQLite sidecars that carry
        // any not-yet-checkpointed writes.
        let legacyURL = support.appending(path: "default.store")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: legacyURL.path + suffix)
            let destination = URL(fileURLWithPath: groupURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                AppLog.data.error("Store migration failed for \(suffix, privacy: .public): \(error, privacy: .public)")
                return
            }
        }

        AppLog.data.info("Migrated the store into the app group")
    }

    /// Make sure the store's parent directory exists.
    ///
    /// `Library/Application Support` is not present in a fresh app container, so
    /// the first launch on a new device logs "Failed to create file; code = 2"
    /// before CoreData recreates it. Creating it first avoids relying on that
    /// recovery path.
    private static func ensureStoreDirectoryExists() {
        let fileManager = FileManager.default
        guard let directory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            AppLog.data.warning("Could not resolve Application Support directory")
            return
        }

        // `create: true` above handles it, but an explicit call keeps the
        // intent obvious and covers the case where the URL resolves without
        // the directory being created.
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Container used by the running app.
    ///
    /// Falls back to a local store when CloudKit is unavailable — no iCloud
    /// account, container not yet created in the developer portal, entitlement
    /// mismatch — rather than refusing to launch. Sync begins on a later launch
    /// once the account and container are in place.
    static func appContainerWithFallback() -> ModelContainer {
        if isRunningTests {
            // Under a test host, use a throwaway store so tests never touch the
            // user's data or the network.
            if let container = try? appContainer(inMemory: true) {
                return container
            }
        }

        if canUseCloudKit {
            do {
                return try appContainer(cloudKit: true)
            } catch {
                AppLog.data.warning("CloudKit container unavailable, using local store: \(error, privacy: .public)")
            }
        }

        do {
            return try appContainer(cloudKit: false)
        } catch {
            AppLog.data.error("Local store unavailable, using in-memory store: \(error, privacy: .public)")
        }

        do {
            return try appContainer(inMemory: true)
        } catch {
            fatalError("Could not create any model container: \(error)")
        }
    }
}
