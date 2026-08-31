import Foundation
import OSLog
import SwiftData

/// Writes the whole database out as a zip of YAML files.
///
/// The record writers below are the counterpart to `DatabaseImporter`'s
/// readers, and the two are meant to be read side by side: every key written
/// here is the first spelling of an entry in `DatabaseImporter.Key`, and adding
/// a field means touching both. `DatabaseArchiveTests` has a guard for the
/// mistake that follows from forgetting —
/// `selfExportReportsNoUnknownFields` fails if this writes a key the importer
/// does not list.
@MainActor
struct DatabaseExporter {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Build the archive.
    ///
    /// Fetches are unsorted because the archive is a set of records addressed by
    /// UUID, not an ordered document — order is carried by each record's
    /// `sortIndex`.
    func makeArchive(date: Date = Date()) throws -> Data {
        let spaces = (try? context.fetch(FetchDescriptor<Space>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let reminders = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        let summaries = (try? context.fetch(FetchDescriptor<SavedAISummary>())) ?? []

        var entries: [Zip.Entry] = [
            Zip.Entry(
                path: ArchiveFormat.manifestPath,
                data: Data(manifest(
                    date: date,
                    spaces: spaces.count,
                    todos: todos.count,
                    reminders: reminders.count,
                    summaries: summaries.count
                ).utf8)
            )
        ]

        for space in spaces {
            entries.append(entry(kind: .space, uuid: space.uuid, body: yaml(for: space)))
        }
        for todo in todos {
            entries.append(entry(kind: .todo, uuid: todo.uuid, body: yaml(for: todo)))
        }
        for reminder in reminders {
            entries.append(entry(kind: .reminder, uuid: reminder.uuid, body: yaml(for: reminder)))
        }
        for summary in summaries {
            entries.append(entry(kind: .summary, uuid: summary.uuid, body: yaml(for: summary)))
        }

        AppLog.data.info("Exporting \(entries.count - 1, privacy: .public) records")
        return try ZipWriter.build(entries)
    }

    /// Write the archive to a file and return its location.
    ///
    /// Used by the share/export UI, which needs a URL rather than bytes.
    func writeArchive(to directory: URL, date: Date = Date()) throws -> URL {
        let data = try makeArchive(date: date)
        let url = directory.appending(path: ArchiveFormat.suggestedFilename(date: date))
        try data.write(to: url, options: .atomic)
        return url
    }

    private func entry(kind: ArchiveFormat.RecordKind, uuid: UUID, body: String) -> Zip.Entry {
        Zip.Entry(
            path: "\(kind.directory)/\(uuid.uuidString).yaml",
            data: Data(body.utf8)
        )
    }

    // MARK: Records

    private func manifest(
        date: Date,
        spaces: Int,
        todos: Int,
        reminders: Int,
        summaries: Int
    ) -> String {
        YAMLWriter.document([
            ("formatVersion", .scalar(String(ArchiveFormat.currentVersion))),
            ("application", .scalar("TODO")),
            ("exportedAt", .scalar(YAMLDateFormats.string(from: date))),
            ("counts", .mapping([
                "spaces": .scalar(String(spaces)),
                "todos": .scalar(String(todos)),
                "reminders": .scalar(String(reminders)),
                "summaries": .scalar(String(summaries)),
            ])),
        ])
    }

    private func yaml(for space: Space) -> String {
        YAMLWriter.document([
            ("uuid", .scalar(space.uuid.uuidString)),
            ("name", .scalar(space.name)),
            ("symbolName", .scalar(space.symbolName)),
            ("colorHex", .scalar(space.colorHex)),
            ("sortIndex", .scalar(String(space.sortIndex))),
            ("isHiddenByFocus", .scalar(String(space.isHiddenByFocus))),
            ("createdAt", .scalar(YAMLDateFormats.string(from: space.createdAt))),
        ])
    }

    private func yaml(for todo: Todo) -> String {
        var pairs: [(String, YAMLValue)] = [
            ("uuid", .scalar(todo.uuid.uuidString)),
            ("title", .scalar(todo.title)),
        ]

        // Omit empty optional text rather than writing `notes: ""` — a smaller
        // file, and the importer treats absent and empty identically.
        if !todo.notes.isEmpty { pairs.append(("notes", .scalar(todo.notes))) }
        if !todo.notesSummary.isEmpty {
            pairs.append(("notesSummary", .scalar(todo.notesSummary)))
        }

        pairs.append(("state", .scalar(todo.stateRaw)))
        pairs.append(("bucket", .scalar(todo.bucketRaw)))

        if let assignedDate = todo.assignedDate {
            pairs.append(("assignedDate", .scalar(YAMLDateFormats.string(from: assignedDate))))
            pairs.append(("assignedHasTime", .scalar(String(todo.assignedHasTime))))
        }
        if let dueDate = todo.dueDate {
            pairs.append(("dueDate", .scalar(YAMLDateFormats.string(from: dueDate))))
            pairs.append(("dueHasTime", .scalar(String(todo.dueHasTime))))
        }
        // The anchor date, not the "this week"/"next week" reading of it. An
        // archive is a record of what the rows held, and the reading is only
        // true relative to the moment it was taken — restoring a backup a
        // fortnight later would otherwise silently move work forward.
        if let weekAnchor = todo.weekAnchor {
            pairs.append(("weekAnchor", .scalar(YAMLDateFormats.string(from: weekAnchor))))
        }
        if let duration = todo.duration {
            pairs.append(("duration", .scalar(String(duration))))
        }

        pairs.append(("isProject", .scalar(String(todo.isProject))))
        if let colorHex = todo.colorHex {
            pairs.append(("colorHex", .scalar(colorHex)))
        }

        pairs.append(("sortIndex", .scalar(String(todo.sortIndex))))
        pairs.append(("isNew", .scalar(String(todo.isNew))))
        if let placement = todo.lastViewedPlacement {
            pairs.append(("lastViewedPlacement", .scalar(placement)))
        }

        if todo.importedFromReminders {
            pairs.append(("importedFromReminders", .scalar("true")))
        }
        if let sourceReminderID = todo.sourceReminderID {
            pairs.append(("sourceReminderID", .scalar(sourceReminderID)))
        }

        pairs.append(("createdAt", .scalar(YAMLDateFormats.string(from: todo.createdAt))))
        pairs.append(("modifiedAt", .scalar(YAMLDateFormats.string(from: todo.modifiedAt))))
        if let resolvedAt = todo.resolvedAt {
            pairs.append(("resolvedAt", .scalar(YAMLDateFormats.string(from: resolvedAt))))
        }

        // Recurrence, written only when the to-do actually has a schedule, so
        // the overwhelming majority of records are unchanged in size and shape.
        // Each column is written under its own key rather than as a nested map:
        // the format's whole premise is that a record is hand-editable, and a
        // flat `recurrenceFrequency: weekly` is far easier to correct than a
        // nested structure.
        if let rule = todo.recurrenceRule {
            pairs.append(("recurrenceMode", .scalar(rule.mode.rawValue)))
            pairs.append(("recurrenceFrequency", .scalar(rule.frequency.rawValue)))
            pairs.append(("recurrenceInterval", .scalar(String(rule.interval))))
            pairs.append(("recurrenceStatus", .scalar(rule.status.rawValue)))

            if !rule.weekdays.isEmpty {
                pairs.append((
                    "recurrenceWeekdays",
                    .scalar(rule.weekdays.sorted().map(String.init).joined(separator: ","))
                ))
            }
            if let dayOfMonth = rule.dayOfMonth {
                pairs.append(("recurrenceDayOfMonth", .scalar(String(dayOfMonth))))
            }
            if let minutes = rule.timeOfDayMinutes {
                pairs.append(("recurrenceTimeOfDayMinutes", .scalar(String(minutes))))
            }
            if let endDate = rule.endDate {
                pairs.append((
                    "recurrenceEndDate", .scalar(YAMLDateFormats.string(from: endDate))
                ))
            }
        }
        if let nextDate = todo.recurrenceNextDate {
            pairs.append(("recurrenceNextDate", .scalar(YAMLDateFormats.string(from: nextDate))))
        }

        // Relationships by UUID. The inverse sides (`subtasks`, `reminders`) are
        // deliberately not written: they are derivable from the forward edge,
        // and writing both invites the two to disagree in a hand-edited file.
        if let spaceUUID = todo.space?.uuid {
            pairs.append(("space", .scalar(spaceUUID.uuidString)))
        }
        if let parentUUID = todo.parent?.uuid {
            pairs.append(("parent", .scalar(parentUUID.uuidString)))
        }
        // The forward edge only, matching `parent` above: `recurrenceInstances`
        // is derivable from it.
        if let templateUUID = todo.recurrenceTemplate?.uuid {
            pairs.append(("recurrenceTemplate", .scalar(templateUUID.uuidString)))
        }

        return YAMLWriter.document(pairs)
    }

    private func yaml(for reminder: Reminder) -> String {
        var pairs: [(String, YAMLValue)] = [
            ("uuid", .scalar(reminder.uuid.uuidString)),
            ("kind", .scalar(reminder.kindRaw)),
        ]

        if let fireDate = reminder.fireDate {
            pairs.append(("fireDate", .scalar(YAMLDateFormats.string(from: fireDate))))
        }
        if let latitude = reminder.latitude {
            pairs.append(("latitude", .scalar(String(latitude))))
        }
        if let longitude = reminder.longitude {
            pairs.append(("longitude", .scalar(String(longitude))))
        }
        pairs.append(("radius", .scalar(String(reminder.radius))))
        if let placeName = reminder.placeName {
            pairs.append(("placeName", .scalar(placeName)))
        }
        pairs.append(("trigger", .scalar(reminder.triggerRaw)))
        pairs.append(("isActive", .scalar(String(reminder.isActive))))
        pairs.append(("createdAt", .scalar(YAMLDateFormats.string(from: reminder.createdAt))))

        if let todoUUID = reminder.todo?.uuid {
            pairs.append(("todo", .scalar(todoUUID.uuidString)))
        }

        return YAMLWriter.document(pairs)
    }

    private func yaml(for summary: SavedAISummary) -> String {
        var pairs: [(String, YAMLValue)] = [
            ("uuid", .scalar(summary.uuid.uuidString)),
            ("generatedOn", .scalar(YAMLDateFormats.string(from: summary.generatedOn))),
        ]

        if let quick = summary.summary.quickSummary {
            pairs.append(("quickSummary", .scalar(quick)))
        }
        pairs.append((
            "detailedSummary",
            .list(summary.summary.detailedSummary.map { .scalar($0) })
        ))

        // The fingerprint is compared with `==` and never parsed, so it is
        // exported as a nested mapping purely so a reader can see what the
        // summary was generated from.
        let fingerprint = summary.fingerprint
        pairs.append(("fingerprint", .mapping([
            "instructions": .scalar(fingerprint.instructions),
            "user": .list(fingerprint.user.map { .scalar($0) }),
            "weather": .list(fingerprint.weather.map { .scalar($0) }),
            "todos": .list(fingerprint.todos.map { .scalar($0) }),
            "events": .list(fingerprint.events.map { .scalar($0) }),
        ])))

        return YAMLWriter.document(pairs)
    }
}
