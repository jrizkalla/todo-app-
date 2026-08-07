# Design seams for future features

The spec lists four features to design for but not implement. This documents the
seams already in place so each becomes an additive change rather than a
refactor.

## Shared foundations

Three pieces are deliberately free of any SwiftUI dependency, so a widget
extension, a CLI, or an intent handler can link them directly:

| Piece | File | Role |
| --- | --- | --- |
| `AppSchema` | `Models/ModelContainer+App.swift` | The single model list. Any target opens the same store by calling `ModelContainer.appContainer()`. |
| `TodoStore` | `Services/TodoStore.swift` | Every mutation, with the completion and filing rules applied. No view touches `ModelContext` directly. |
| `TodoQueries` | `Services/TodoQueries.swift` | Pure functions over `[Todo]`. Same filters for a widget timeline as for the sidebar. Main-actor-isolated, since `@Model` types are. |

`AppSchema.appGroupIdentifier` (`group.com.johnrizkalla.app.TODO`) is where the
store and `UserDefaults` live so multiple processes can share them.

**One setup step remains**: the App Group capability is not yet enabled on the
bundle id. Until it is, `AppSettings` falls back to `UserDefaults.standard` and
the store uses its default location — fine for the app alone, but a widget or
CLI would see a different database. Enable the capability in the developer
portal and add it to the entitlements before building either.

## Widgets

- Add a Widget Extension target; add it to the App Group.
- Open the store with `ModelContainer.appContainer()`.
- Build timelines from `TodoQueries.today(_:)` / `.overdue(_:)` — no new
  filtering code.
- `Todo.uuid` is a stable identifier for deep links, independent of SwiftData's
  `PersistentIdentifier`, which is not stable across processes.

## CLI on macOS

- Add a command-line target linking the model and service files.
- `TodoStore` is the whole API surface: `createTodo`, `setState`, `move`.
- `ExportService.markdown(for:)` already renders a list for terminal output.
- `TodoStore` is `@MainActor`; a CLI entry point needs `@main` with an async
  `main()` hopping to the main actor.

## Siri and App Intents

- `TodoStore`'s methods map one-to-one onto intents: `createTodo` →
  "Add a to-do", `setState` → "Mark done".
- `setState` returns `StateChangeOutcome` rather than mutating blindly, so an
  intent can surface the subtask prompt as a disambiguation instead of silently
  cascading.
- `Todo.uuid` and `Space.uuid` back `AppEntity` identifiers.
- `TitleParser` gives a spoken phrase the same date/duration handling the UI
  has — "remind me to clean the car tomorrow" resolves identically.

## Export

`Services/ExportService.swift` holds the mapping, unwired to any UI:

- `makeReminder(from:in:)` — `Todo` → `EKReminder`, carrying dates and alarms.
- `makeEvent(from:in:defaultDuration:)` — `Todo` → `EKEvent`, using the todo's
  duration or the configured default, all-day when the todo has no time.
- `markdown(for:)` — nested checklist text for manual export.

Both EventKit paths need write access; the import flow already requests
`requestFullAccessToReminders`, and calendar export would add the matching
calendar request. `NSCalendarsFullAccessUsageDescription` is already in
`Info.plist`.

## Notes

- Every model property is optional or defaulted and no property is unique, which
  CloudKit mirroring requires. `ModelTests.schemaIsCloudKitCompatible` walks the
  schema and fails if a future change breaks either rule.
- `CompletionState` and `Bucket` persist as raw strings, so new cases can be
  added without a migration.
