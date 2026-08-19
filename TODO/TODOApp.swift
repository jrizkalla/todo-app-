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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
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
