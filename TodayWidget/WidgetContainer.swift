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
    ///
    /// No mirroring: the extension runs for seconds and gets no pushes, so it
    /// cannot keep up with CloudKit, and a second mirror of one store in another
    /// process is unsupported. The app syncs, and reloads these timelines when
    /// an import lands — see `CloudImportWidgetReloader`. Writes made here (a
    /// tick from the home screen) go into the store's history and are exported
    /// by the app's mirror on its next run.
    static func widgetContainer() throws -> ModelContainer {
        guard let url = AppSchema.storeURL else {
            throw WidgetStoreError.appGroupUnavailable
        }

        let configuration = ModelConfiguration(
            schema: AppSchema.schema,
            url: url,
            cloudKitDatabase: .none
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
