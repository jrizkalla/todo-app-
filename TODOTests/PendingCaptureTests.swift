import Testing
import Foundation
@testable import TODO

/// The handoff between the Control Center button and the app.
///
/// The button writes its row in the widget extension and then asks the system
/// to foreground the app, so the new to-do's id has to cross a process
/// boundary. These cover the part that can be tested in one process: that a
/// waiting id survives the trip, and that it is answered exactly once.
///
/// "Exactly once" is the half worth guarding. Two windows both claiming one
/// press would put the caret in the same row twice, and an id left behind would
/// have tomorrow's launch re-open a to-do the user has since filled in.
struct PendingCaptureTests {

    /// A suite of its own per test, so these never touch the real app group and
    /// cannot leak a pending capture into a later run.
    private func makeDefaults() -> UserDefaults {
        let suite = "PendingCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aWaitingIDSurvivesTheTrip() {
        let defaults = makeDefaults()
        let id = UUID()

        PendingCapture.set(id, in: defaults)

        #expect(PendingCapture.take(from: defaults) == id)
    }

    /// Taking clears it: one press is one row to name.
    @Test func takingClearsIt() {
        let defaults = makeDefaults()
        PendingCapture.set(UUID(), in: defaults)

        _ = PendingCapture.take(from: defaults)

        #expect(PendingCapture.take(from: defaults) == nil)
    }

    /// Nothing waiting is not an error, just nothing to do — the app asks on
    /// every launch and every foreground, and almost always gets this.
    @Test func nothingWaitingIsNil() {
        #expect(PendingCapture.take(from: makeDefaults()) == nil)
    }

    /// A value that is not a UUID is discarded rather than trusted. It cannot
    /// name a row, so keeping it would only mean asking again forever.
    @Test func garbageIsDiscarded() {
        let defaults = makeDefaults()
        defaults.set("not-a-uuid", forKey: PendingCapture.key)

        #expect(PendingCapture.take(from: defaults) == nil)
        #expect(defaults.string(forKey: PendingCapture.key) == nil)
    }
}
