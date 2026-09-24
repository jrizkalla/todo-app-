import CoreData
import WidgetKit

/// Reloads the widgets when CloudKit brings in changes made on another device.
///
/// The widgets read the shared store but never sync it themselves — an
/// extension lives for a few seconds per timeline and receives no pushes, so
/// it cannot be the one that notices a remote edit. The app is: its mirroring
/// imports on every push, launch and foreground, including background launches
/// from a silent push. Without this, a change from another device lands in the
/// store and the home and lock screens keep showing the old day until midnight
/// or the next local edit.
///
/// Every successful import reloads, rather than only ones that touched today:
/// the event does not say what changed, and CloudKit only pushes when a record
/// did, so an import with nothing in it is rare outside the foreground — where
/// WidgetKit does not count reloads against the budget anyway.
enum CloudImportWidgetReloader {
    private static var observer: NSObjectProtocol?

    /// Begin listening. Safe to call more than once.
    static func start() {
        guard observer == nil else { return }

        // `object: nil` because SwiftData never hands out the
        // `NSPersistentCloudKitContainer` it mirrors through.
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import,
                  // The same event is posted once when it starts and again when
                  // it ends; only the second has anything in the store.
                  event.endDate != nil,
                  event.succeeded
            else { return }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
