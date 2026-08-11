import Foundation
import SwiftData

extension ModelContainer {
    /// The shared store, opened read-write for the widget.
    ///
    /// Deliberately not `appContainer`: that one falls back to the app's own
    /// private container and can enable CloudKit mirroring, neither of which is
    /// right in an extension. The widget wants exactly one thing — the group's
    /// store, or nothing — so a missing app group throws here instead of
    /// silently opening an empty database the user would see as lost data.
    static func widgetContainer() throws -> ModelContainer {
        guard let url = AppSchema.storeURL else {
            throw WidgetStoreError.appGroupUnavailable
        }

        let configuration = ModelConfiguration(
            schema: AppSchema.schema,
            url: url,
            cloudKitDatabase: .automatic
        )

        // Same plan as the app: the widget opens the same file, so whichever
        // runs first has to be able to migrate it. Without this the widget
        // would fail to open a store the app had not upgraded yet.
        return try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

enum WidgetStoreError: Error {
    case appGroupUnavailable
}
