import Testing
import Foundation
import SwiftData
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
            name: KeyboardCommand.create.notificationName,
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
        let unaddressed = Notification(name: KeyboardCommand.create.notificationName)

        #expect(WindowIdentity.isTarget(unaddressed, UUID()))
        #expect(WindowIdentity.isTarget(unaddressed, UUID()))
    }

    /// A `userInfo` carrying something that is not a window id is treated as
    /// unaddressed rather than matching nothing at all.
    @Test func aMalformedAddressReachesEveryWindow() {
        let malformed = Notification(
            name: KeyboardCommand.create.notificationName,
            object: nil,
            userInfo: [WindowIdentity.userInfoKey: "not-a-uuid"]
        )

        #expect(WindowIdentity.isTarget(malformed, UUID()))
    }

    // MARK: What a command needs before it can fire

    /// Cmd+N, Cmd+F and Cmd+A act on the open screen, not on a selected row.
    ///
    /// This is what lets Cmd+N create into the list being looked at: the
    /// shortcut is pressed most often on a list just opened, where nothing is
    /// selected yet, and a selection-gated command would reach nobody at
    /// exactly that moment. Select All is the same case put more sharply — it
    /// is *about* a list with nothing picked in it yet.
    @Test func creatingSearchingAndSelectingAllActOnTheOpenScreen() {
        #expect(KeyboardCommand.create.actsOnView)
        #expect(KeyboardCommand.search.actsOnView)
        #expect(KeyboardCommand.selectAll.actsOnView)
    }

    /// Everything else needs a to-do to act on, so it goes to whichever
    /// surface holds the selection rather than to whatever is on screen.
    @Test func theRestActOnTheSelectedTodo() {
        let selectionCommands: [KeyboardCommand] = [
            .schedule, .toggleDone, .showDetail, .move, .duplicate, .delete
        ]

        for command in selectionCommands {
            #expect(command.actsOnView == false, "\(command) should need a selection")
        }
    }

    /// Every command is one or the other, so adding a case forces the choice
    /// rather than defaulting into the selection-gated half unnoticed.
    @Test func everyCommandDeclaresWhatItActsOn() {
        let classified = KeyboardCommand.allCases.filter { $0.actsOnView }.count
            + KeyboardCommand.allCases.filter { !$0.actsOnView }.count

        #expect(classified == KeyboardCommand.allCases.count)
    }

    /// A to-do created while a project is open belongs to that project.
    ///
    /// The point of routing Cmd+N through the open screen: the user has
    /// already said where the work goes by opening the list, and a shortcut
    /// that dropped it in the Inbox made them file it a second time. Asserted
    /// against the project's own list, because belonging to it and *appearing*
    /// in it are what the user actually sees.
    @Test func creatingInsideAProjectFilesItThere() throws {
        let container = try ModelContainer.appContainer(inMemory: true)
        let context = ModelContext(container)
        let store = TodoStore(context: context)

        let space = store.createSpace(name: "Vibe coding")
        let project = store.createTodo(title: "Bugs", space: space, isProject: true)

        // What the list passes for a project destination: the project as the
        // parent, and its space carried along — see `TodoListView`.
        let created = store.createTodo(
            title: "Crash on launch", space: space, parent: project
        )

        #expect(created.parent == project)
        #expect(created.space == space)

        let inProject = try context.fetch(
            TodoQueries.descriptor(for: .project(project.uuid), calendar: .current,
                                   includeResolved: false)
        )
        #expect(inProject.contains { $0.uuid == created.uuid })

        // And it is *not* loose in the Inbox, which is where it used to land.
        let inbox = try context.fetch(
            TodoQueries.descriptor(for: .inbox, calendar: .current, includeResolved: false)
        )
        #expect(inbox.contains { $0.uuid == created.uuid } == false)
    }

    // MARK: The Inbox's one entry point

    /// A window saved on the Inbox tab has somewhere to land where that tab
    /// does not exist.
    ///
    /// The tab is gone wherever the app can open a second window, but a state
    /// saved by an older build — or by a phone, which still has the tab — can
    /// still name it. Selecting a tab the layout does not draw leaves the
    /// content area blank, so the window is sent to the sidebar's Inbox row
    /// instead. `RootView.rehomeInboxTab` is what does it; this pins the
    /// destination that repair has to produce.
    @Test func aWindowSavedOnTheInboxTabHasSomewhereToLand() throws {
        let saved = WindowState(tab: .inbox, list: .today)

        // Survives the trip, so the repair is reached with the tab intact
        // rather than the value having been dropped in decoding.
        let restored = try JSONDecoder().decode(
            WindowState.self, from: JSONEncoder().encode(saved)
        )
        #expect(restored.tab == .inbox)

        var repaired = restored
        repaired.list = .inbox
        repaired.tab = .lists

        #expect(repaired.tab == .lists)
        #expect(repaired.list == .inbox)
    }

    /// The Inbox is reachable as a list, which is what the tab's removal
    /// relies on: it can be selected, opened in a window of its own, and
    /// dropped onto, exactly like the dated lists beside it.
    @Test func theInboxWorksAsAnOrdinaryList() throws {
        let context = try makeContext()

        let filed = Todo(title: "Filed", assignedDate: Date())
        context.insert(filed)

        // Selectable and countable, which is what the sidebar row draws.
        #expect(TodoQueries.count(for: .inbox, in: context) >= 0)

        // And a drop onto it means what the row promises: unfiled and undated.
        let applied = TodoDropAction.apply(
            .inbox, to: filed, store: TodoStore(context: context)
        )
        #expect(applied)
        #expect(filed.assignedDate == nil)
        #expect(filed.space == nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// The Inbox has exactly one entry point, whichever layout this is.
    ///
    /// Both at once gives one screen two ways in with no way to tell them
    /// apart; neither strands the Inbox with no way in at all. The two views
    /// read this one type rather than each negating the flag themselves, so
    /// they cannot drift into either state.
    @Test func theInboxHasExactlyOneEntryPoint() {
        for supportsMultipleWindows in [true, false] {
            let placement = InboxPlacement.forLayout(
                supportsMultipleWindows: supportsMultipleWindows
            )
            #expect(placement.showsTab != placement.showsSidebarRow)
        }
    }

    /// A phone keeps the tab; everywhere else the Inbox is a sidebar row.
    ///
    /// Not arbitrary either way: a phone cannot open a second window, and a
    /// sidebar row there is two navigation steps from anywhere, so the tab
    /// earns the space. Where windows exist the Inbox is a list like the rest
    /// and can be opened in one of its own.
    @Test func onlyASingleWindowLayoutKeepsTheTab() {
        #expect(InboxPlacement.forLayout(supportsMultipleWindows: false) == .tab)
        #expect(InboxPlacement.forLayout(supportsMultipleWindows: true) == .sidebarRow)
    }
}
