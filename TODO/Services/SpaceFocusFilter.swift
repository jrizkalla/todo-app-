import AppIntents
import Foundation
import SwiftData

/// A space, as the system's Focus Filter UI sees it.
///
/// Focus filters are configured in Settings, outside the app, so the spaces the
/// user picks there have to be addressable without a live `ModelContext`. The
/// entity carries the space's `uuid` as its identifier and a snapshot of the
/// name and symbol for display; the intent resolves it back to the real `Space`
/// when the filter runs.
struct SpaceEntity: AppEntity, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbolName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Space", numericFormat: "\(placeholder: .int) spaces")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: symbolName)
        )
    }

    static var defaultQuery = SpaceEntityQuery()

    init(id: UUID, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    @MainActor
    init(_ space: Space) {
        self.init(
            id: space.uuid,
            name: space.name.isEmpty ? "Untitled Space" : space.name,
            symbolName: space.symbolName
        )
    }
}

/// Supplies the space list to the Focus Filter picker in Settings.
struct SpaceEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SpaceEntity] {
        try await allSpaces().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SpaceEntity] {
        try await allSpaces()
    }

    /// Every space, in sidebar order.
    ///
    /// Settings runs this out of process, so it opens its own container against
    /// the shared app-group store rather than reusing the app's environment.
    @MainActor
    private func allSpaces() async throws -> [SpaceEntity] {
        let container = try ModelContainer.appContainer(cloudKit: false)
        let spaces = try container.mainContext.fetch(FetchDescriptor<Space>())
        return spaces
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(SpaceEntity.init)
    }
}

/// Lets each system Focus choose which spaces stay visible.
///
/// This is what puts TODO under Settings → Focus → *a Focus* → Focus Filters.
/// The system runs it when the Focus turns on and again when it turns off,
/// passing the spaces the user selected; everything not selected is marked
/// hidden, and the app's sidebar and lists read that flag.
struct SpaceFocusFilterIntent: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Filter Spaces"

    static var description = IntentDescription(
        "Choose which spaces stay visible in TODO while this Focus is on."
    )

    /// The spaces to keep visible. Empty means "no filtering" rather than "hide
    /// everything" — a filter the user added but never configured should not
    /// blank out the app.
    @Parameter(title: "Visible Spaces")
    var spaces: [SpaceEntity]?

    /// Summary shown in Settings beneath the filter's row.
    var displayRepresentation: DisplayRepresentation {
        guard let spaces, !spaces.isEmpty else {
            return DisplayRepresentation(
                title: "All Spaces",
                subtitle: "Every space stays visible"
            )
        }

        let names = spaces.map(\.name).joined(separator: ", ")
        return DisplayRepresentation(
            title: "\(spaces.count) Space\(spaces.count == 1 ? "" : "s")",
            subtitle: "\(names)"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try ModelContainer.appContainer(cloudKit: false)
        let context = container.mainContext
        let allSpaces = try context.fetch(FetchDescriptor<Space>())

        // No selection means the filter is inactive: clear every flag so the
        // app returns to showing everything.
        let visibleIDs = Set((spaces ?? []).map(\.id))

        for space in allSpaces {
            space.isHiddenByFocus = visibleIDs.isEmpty ? false : !visibleIDs.contains(space.uuid)
        }

        if context.hasChanges {
            try context.save()
        }

        return .result()
    }
}
