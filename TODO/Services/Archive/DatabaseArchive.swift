import Foundation

/// The shape of an exported archive: a zip of YAML files.
///
/// ```
/// TODO-Export-2026-08-11.todozip
/// ├── manifest.yaml          format version, export date, record counts
/// ├── spaces/<uuid>.yaml
/// ├── todos/<uuid>.yaml
/// ├── reminders/<uuid>.yaml
/// └── summaries/<uuid>.yaml
/// ```
///
/// One file per record rather than one file per table, because that is what
/// makes the export useful outside the app: a record is diffable, greppable, and
/// individually editable, and a single corrupt file costs one record instead of
/// every record of that type.
///
/// Relationships are stored as UUIDs, never as file paths or indices. A UUID
/// survives being exported from one database and imported into another, and it
/// is what lets the importer resolve links in a second pass without caring what
/// order the files arrived in.
enum ArchiveFormat {

    /// Bumped when the layout changes in a way the importer must know about.
    ///
    /// The importer does *not* refuse an unknown version. It reads what it
    /// recognizes and reports the rest, because refusing is exactly the failure
    /// mode this feature exists to avoid.
    static let currentVersion = 1

    static let manifestPath = "manifest.yaml"

    /// Directory names, and the record kind each holds.
    enum RecordKind: String, CaseIterable {
        case space
        case todo
        case reminder
        case summary

        var directory: String {
            switch self {
            case .space: "spaces"
            case .todo: "todos"
            case .reminder: "reminders"
            case .summary: "summaries"
            }
        }

        /// Directory names accepted on import, so a rename does not orphan an
        /// older archive.
        var acceptedDirectories: [String] {
            switch self {
            case .space: ["spaces", "space"]
            case .todo: ["todos", "todo", "tasks", "items"]
            case .reminder: ["reminders", "reminder", "alerts"]
            case .summary: ["summaries", "summary", "aisummaries"]
            }
        }

        static func forDirectory(_ name: String) -> RecordKind? {
            let normalized = name.lowercased().filter { $0.isLetter }
            return allCases.first { $0.acceptedDirectories.contains(normalized) }
        }
    }

    /// File extension for an exported archive.
    ///
    /// A plain `.zip` so the file opens anywhere without a custom UTI — the
    /// point of choosing zip over a proprietary container.
    static let fileExtension = "zip"

    static func suggestedFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "TODO-Export-\(formatter.string(from: date)).\(fileExtension)"
    }
}

/// What an import did, and everything it could not do.
///
/// The importer never throws for a bad record — it records the problem here and
/// keeps going — so this report is the only way the user learns that something
/// was dropped. It is shown after every import, not just failures.
struct ImportReport {
    var createdSpaces = 0
    var updatedSpaces = 0
    var createdTodos = 0
    var updatedTodos = 0
    var createdReminders = 0
    var updatedReminders = 0
    var createdSummaries = 0

    /// Files that could not be read as a record at all.
    var skippedFiles: [String] = []
    /// Fields present in the archive that this build has nowhere to put.
    var unknownFields: Set<String> = []
    /// Relationships naming a record that is not in the archive.
    var danglingReferences: [String] = []
    /// Anything else worth telling the user.
    var warnings: [String] = []

    /// Version stamped in the archive, when it had one.
    var archiveVersion: Int?

    var totalCreated: Int {
        createdSpaces + createdTodos + createdReminders + createdSummaries
    }

    var totalUpdated: Int {
        updatedSpaces + updatedTodos + updatedReminders
    }

    var hasProblems: Bool {
        !skippedFiles.isEmpty || !danglingReferences.isEmpty || !warnings.isEmpty
    }

    /// One-line result for the settings row.
    var headline: String {
        if totalCreated == 0 && totalUpdated == 0 {
            return "Nothing to import."
        }
        var parts: [String] = []
        if totalCreated > 0 { parts.append("\(totalCreated) added") }
        if totalUpdated > 0 { parts.append("\(totalUpdated) updated") }
        return parts.joined(separator: ", ") + "."
    }

    /// The detail the user sees when something did not come through cleanly.
    var details: [String] {
        var lines: [String] = []

        if createdSpaces + updatedSpaces > 0 {
            lines.append("Spaces: \(createdSpaces) added, \(updatedSpaces) updated")
        }
        if createdTodos + updatedTodos > 0 {
            lines.append("To-dos: \(createdTodos) added, \(updatedTodos) updated")
        }
        if createdReminders + updatedReminders > 0 {
            lines.append("Reminders: \(createdReminders) added, \(updatedReminders) updated")
        }
        if createdSummaries > 0 {
            lines.append("Summaries: \(createdSummaries) added")
        }

        if !skippedFiles.isEmpty {
            let shown = skippedFiles.prefix(5).joined(separator: ", ")
            let more = skippedFiles.count > 5 ? " and \(skippedFiles.count - 5) more" : ""
            lines.append("Skipped \(skippedFiles.count) unreadable file(s): \(shown)\(more)")
        }
        if !danglingReferences.isEmpty {
            lines.append(
                "\(danglingReferences.count) link(s) pointed at records not in the archive; "
                + "those items were imported without them."
            )
        }
        if !unknownFields.isEmpty {
            let shown = unknownFields.sorted().prefix(8).joined(separator: ", ")
            lines.append("Ignored unrecognized field(s): \(shown)")
        }
        lines.append(contentsOf: warnings)

        return lines
    }
}
