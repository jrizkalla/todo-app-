import Foundation
import OSLog
import UserNotifications
import CoreLocation

/// Schedules and cancels the local notifications behind reminders.
///
/// Date reminders use a calendar trigger. Location reminders are registered
/// with CoreLocation region monitoring, which delivers a notification when the
/// user arrives at or leaves the place.
@MainActor
final class NotificationScheduler: NSObject {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let locationManager = CLLocationManager()

    /// Regions the app is currently monitoring, keyed by reminder id.
    private var monitoredIdentifiers: Set<String> = []

    override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: Authorization

    /// Ask for notification permission. Safe to call repeatedly.
    @discardableResult
    func requestNotificationAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.reminders.error("Notification authorization failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Ask for the location permission geofencing needs.
    ///
    /// Region monitoring keeps working when the app is closed, which requires
    /// "Always". iOS grants that only after "When In Use", so this asks in that
    /// order.
    func requestLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            #if os(iOS)
            locationManager.requestAlwaysAuthorization()
            #endif
        default:
            break
        }
    }

    var locationAuthorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    // MARK: Scheduling

    /// Register every active reminder, replacing what was scheduled before.
    ///
    /// Called at launch and after edits; rescheduling wholesale keeps the
    /// system's view consistent with the store without incremental bookkeeping.
    func syncAll(reminders: [Reminder]) async {
        let active = reminders.filter { $0.isActive }

        await cancelAllDateNotifications()
        for reminder in active where reminder.kind == .dateTime {
            await schedule(dateReminder: reminder)
        }

        stopMonitoringAllRegions()
        for reminder in active where reminder.kind == .location {
            startMonitoring(locationReminder: reminder)
        }
    }

    private func schedule(dateReminder reminder: Reminder) async {
        guard let fireDate = reminder.fireDate, fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = reminder.todo?.plainTitle ?? "Reminder"
        content.body = reminder.todo?.notes.isEmpty == false ? String(reminder.todo!.notes.prefix(120)) : ""
        content.sound = .default
        content.userInfo = ["todoID": reminder.todo?.uuid.uuidString ?? ""]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.scheduleIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            AppLog.reminders.error("Failed to schedule \(reminder.scheduleIdentifier, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Begin monitoring a geofence for a location reminder.
    private func startMonitoring(locationReminder reminder: Reminder) {
        guard reminder.hasCoordinates,
              let latitude = reminder.latitude,
              let longitude = reminder.longitude
        else { return }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            AppLog.location.warning("Region monitoring unavailable on this device")
            return
        }

        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: min(reminder.radius, locationManager.maximumRegionMonitoringDistance),
            identifier: reminder.scheduleIdentifier
        )
        region.notifyOnEntry = reminder.trigger == .onArrival
        region.notifyOnExit = reminder.trigger == .onDeparture

        locationManager.startMonitoring(for: region)
        monitoredIdentifiers.insert(reminder.scheduleIdentifier)
    }

    // MARK: Cancelling

    func cancel(_ reminder: Reminder) {
        center.removePendingNotificationRequests(withIdentifiers: [reminder.scheduleIdentifier])
        stopMonitoring(identifier: reminder.scheduleIdentifier)
    }

    private func cancelAllDateNotifications() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
    }

    private func stopMonitoring(identifier: String) {
        for region in locationManager.monitoredRegions where region.identifier == identifier {
            locationManager.stopMonitoring(for: region)
        }
        monitoredIdentifiers.remove(identifier)
    }

    private func stopMonitoringAllRegions() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        monitoredIdentifiers.removeAll()
    }

    /// Deliver the notification for a geofence crossing.
    fileprivate func fireLocationNotification(identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = "You've reached a place with a to-do."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifier)-fired-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                AppLog.location.error("Location notification failed: \(error, privacy: .public)")
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension NotificationScheduler: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in fireLocationNotification(identifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in fireLocationNotification(identifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        AppLog.location.error("Region monitoring failed: \(error, privacy: .public)")
    }
}

extension Todo {
    /// Title with markdown marks stripped, for notification text where markup
    /// would show as literal characters.
    var plainTitle: String {
        guard let attributed = try? AttributedString(
            markdown: title,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return title }
        return String(attributed.characters)
    }
}
