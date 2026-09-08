import Testing
import Foundation
@testable import TODO

/// What one window remembers, and which window a menu command reaches.
@MainActor
struct WindowStateTests {

    // MARK: Restoration

    /// The state a window is keyed on has to survive a relaunch, or "restore
    /// my windows" restores them all onto the default list.
    @Test func stateSurvivesEncoding() throws {
        let original = WindowState(tab: .calendar, list: .project(UUID()))

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WindowState.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.id == original.id)
        #expect(decoded.tab == .calendar)
        #expect(decoded.list == original.list)
    }

    /// Every destination the sidebar can open a window onto, including the two
    /// that carry an id.
    @Test func everyDestinationSurvivesEncoding() throws {
        let destinations: [ListDestination] = [
            .inbox, .today, .tomorrow, .thisWeek, .nextWeek, .anytime, .logbook,
            .space(UUID()), .project(UUID()),
        ]

        for destination in destinations {
            let state = WindowState.showing(destination)
            let decoded = try JSONDecoder().decode(
                WindowState.self, from: JSONEncoder().encode(state)
            )
            #expect(decoded.list == destination)
        }
    }

    // MARK: Identity

    /// Two windows opened on the same list are two windows.
    ///
    /// A `WindowGroup` keyed on a value treats an equal value as the *same*
    /// window and brings the existing one forward instead of opening another.
    /// The per-window id is what keeps "Open in New Window" twice on one
    /// project from merely raising the window already showing it.
    @Test func twoWindowsOnOneListAreDistinct() {
        let project = ListDestination.project(UUID())

        let first = WindowState.showing(project)
        let second = WindowState.showing(project)

        #expect(first.id != second.id)
        #expect(first != second)
        #expect(first.list == second.list)
    }

    /// Opening a window onto a list puts it on the tab that shows lists —
    /// otherwise the window opens on the right list and the wrong screen.
    @Test func openingOnAListShowsTheListsTab() {
        let state = WindowState.showing(.space(UUID()))

        #expect(state.tab == .lists)
    }

    // MARK: Command routing

    /// A command addressed to one window is ignored by the others.
    ///
    /// Every window listens to the same notifications, so without this a single
    /// Cmd+N created an untitled to-do in each of them at once.
    @Test func aCommandReachesOnlyTheWindowItNames() {
        let target = UUID()
        let other = UUID()

        let notification = Notification(
            name: .createInInboxRequested,
            object: nil,
            userInfo: [WindowIdentity.userInfoKey: target]
        )

        #expect(WindowIdentity.isTarget(notification, target))
        #expect(WindowIdentity.isTarget(notification, other) == false)
    }

    /// A command posted with no window in mind is answered by every window.
    ///
    /// That is the behaviour the app had when there was only one window, and it
    /// is the safer fallback: a shortcut that acts twice is a nuisance, one
    /// that silently does nothing looks broken.
    @Test func anUnaddressedCommandReachesEveryWindow() {
        let unaddressed = Notification(name: .createInInboxRequested)

        #expect(WindowIdentity.isTarget(unaddressed, UUID()))
        #expect(WindowIdentity.isTarget(unaddressed, UUID()))
    }

    /// A `userInfo` carrying something that is not a window id is treated as
    /// unaddressed rather than matching nothing at all.
    @Test func aMalformedAddressReachesEveryWindow() {
        let malformed = Notification(
            name: .createInInboxRequested,
            object: nil,
            userInfo: [WindowIdentity.userInfoKey: "not-a-uuid"]
        )

        #expect(WindowIdentity.isTarget(malformed, UUID()))
    }
}
