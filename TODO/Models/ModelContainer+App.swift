import Foundation
import OSLog
import SwiftData

/// The app's schema, in one place so the widget extension and the macOS CLI can
/// open the same store without duplicating the model list.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Todo.self,
        Space.self,
        Reminder.self,
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
    static let cloudKitContainerIdentifier = "iCloud.com.johnrizkalla.app.TODO"
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
            configuration = ModelConfiguration(
                schema: AppSchema.schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: cloudKit
                    ? .private(AppSchema.cloudKitContainerIdentifier)
                    : .none
            )
        }

        return try ModelContainer(for: AppSchema.schema, configurations: [configuration])
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

    /// Whether CloudKit mirroring can be requested safely.
    ///
    /// This has to be decided *before* building the container. When the
    /// container identifier is not provisioned — the entitlement is missing, or
    /// the container has not been created in the developer portal — CoreData's
    /// mirroring delegate traps on a background queue after `ModelContainer`
    /// init has already returned, so a `do`/`catch` around init cannot recover.
    /// Checking the entitlement up front is what keeps that trap from firing.
    static var canUseCloudKit: Bool {
        guard !isRunningTests else { return false }

        // The simulator has no iCloud account by default; asking for mirroring
        // there traps in the same way.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            AppLog.data.info("No iCloud account signed in; using a local store")
            return false
        }

        return true
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
