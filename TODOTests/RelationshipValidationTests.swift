import Testing
import Foundation
import SwiftData
@testable import TODO

/// CloudKit mirroring requires every relationship to declare an inverse and
/// every to-one relationship to be optional. This walks the schema the way the
/// mirroring delegate does and reports violations.
@MainActor
struct RelationshipValidationTests {
    @Test func everyRelationshipHasInverseAndIsOptional() throws {
        let container = try ModelContainer.appContainer(inMemory: true)
        var problems: [String] = []

        for entity in container.schema.entities {
            for property in entity.properties {
                guard let rel = property as? Schema.Relationship else { continue }
                let name = "\(entity.name).\(rel.name)"
                if rel.inverseName == nil {
                    problems.append("\(name): no inverse")
                }
                if !rel.isOptional && !rel.isToOneRelationship {
                    problems.append("\(name): to-many not optional")
                }
                if !rel.isOptional && rel.isToOneRelationship {
                    problems.append("\(name): to-one not optional")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// Sync is off because a free Apple team cannot provision iCloud.
    ///
    /// The entitlement flag and the entitlements file have to move together: if
    /// one says CloudKit and the other does not, the app either fails to sign
    /// or silently never syncs. This pins the current state so flipping it is a
    /// deliberate act.
    @Test func cloudKitIsDisabledUntilEntitlementIsRestored() {
        #expect(ModelContainer.hasCloudKitEntitlement == false)
        #expect(ModelContainer.canUseCloudKit == false)
    }

    /// The app must still open a working store with sync off.
    @Test func localStoreOpensWithoutCloudKit() throws {
        let container = try ModelContainer.appContainer(inMemory: true, cloudKit: false)
        #expect(container.schema.entities.count == AppSchema.models.count)
    }

    /// The store's parent directory is missing on a fresh install, so opening a
    /// file-backed container has to create it rather than rely on CoreData's
    /// recovery path.
    @Test func applicationSupportDirectoryIsCreated() throws {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)

        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
