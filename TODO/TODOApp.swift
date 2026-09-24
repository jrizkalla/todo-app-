//
//  TODOApp.swift
//  TODO
//

import SwiftUI
import SwiftData

@main
struct TODOApp: App {
    /// Built once and shared by every scene. CloudKit mirroring is configured
    /// here; see `ModelContainer.appContainerWithFallback`.
    ///
    /// Resolved lazily through a static so the store is not opened while the
    /// test host is launching.
    var modelContainer: ModelContainer { Self.sharedContainer }

    private static let sharedContainer: ModelContainer = .appContainerWithFallback()

    @State private var settings = AppSettings.shared

    init() {
        // Here rather than in a view: a silent push launches the app in the
        // background with no scene, and that import is exactly the one the
        // widgets most need to hear about.
        CloudImportWidgetReloader.start()
    }

    var body: some Scene {
        // Keyed on `WindowState`, which is what makes windows independent and
        // addressable at once: SwiftUI hands each open window its own binding,
        // so two of them sit on two different lists, and opening one *with* a
        // value puts it straight onto that list. The value is `Codable`, so the
        // system restores the arrangement on the next launch.
        // `defaultValue` is what makes the binding non-optional: a window
        // opened from the Dock or restored without a value still starts
        // somewhere, so `RootView` never has to answer for a missing one.
        WindowGroup(for: WindowState.self) { $state in
            RootView(windowState: $state)
                .environment(settings)
        } defaultValue: {
            WindowState()
        }
        .modelContainer(modelContainer)
        .commands { AppCommands(container: modelContainer) }

        #if os(macOS)
        // Backs a detail popover torn off into a window of its own.
        TodoDetailWindowScene(container: modelContainer, settings: settings)

        Settings {
            SettingsView()
                .environment(settings)
                .modelContainer(modelContainer)
        }
        #endif
    }
}
