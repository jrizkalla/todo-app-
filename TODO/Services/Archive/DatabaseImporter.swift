import Foundation
import OSLog
import SwiftData

/// Reads an exported archive back into the store, tolerating as much drift as it
/// can.
///
/// The design rule is that **an archive is a set of suggestions, not a
/// contract**. Anything the importer understands, it applies; anything it does
/// not, it notes in the `ImportReport` and moves past. Concretely, all of these
/// import successfully rather than failing:
///
/// - fields this build has never heard of (a newer export), which are ignored
/// - fields this build expects that are missing (an older export), which take
///   the model's default
/// - fields holding the wrong type — `"true"` for a number, `3.0` for an `Int` —
///   which are coerced where the meaning is unambiguous
/// - enum cases that no longer exist, which fall back to the model's default
/// - relationships naming a record not in the archive, which are dropped while
///   the record itself is still imported
/// - individual files that are unreadable or not YAML at all, which are skipped
/// - a missing manifest, or one with an unknown format version
///
/// The one thing it will not do is invent data: a field it cannot make sense of
/// leaves the model's default in place rather than guessing.
@MainActor
struct DatabaseImporter {
    let context: ModelContext

    /// How an archive combines with what is already in the store.
    enum Strategy {
        /// Match on UUID: update the record that is already there, insert the
        /// rest. The safe default — re-importing an archive twice is a no-op
        /// rather than a duplication.
        case merge
        /// Delete everything first. What "restore this backup" means.
        case replace
    }

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Entry points

    /// Import from an archive's bytes.
    func importArchive(_ data: Data, strategy: Strategy = .merge) throws -> ImportReport {
        let entries = try ZipReader.entries(in: data)
        return importEntries(entries, strategy: strategy)
    }

    /// Import from a file on disk.
    ///
    /// Wrapped in the security-scoped accessor because the file picker hands
    /// back a URL outside the app's container.
    func importArchive(at url: URL, strategy: Strategy = .merge) throws -> ImportReport {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        return try importArchive(data, strategy: strategy)
    }

    // MARK: The pass structure

    /// Import already-extracted files.
    ///
    /// Runs in three passes, which is what makes file order irrelevant:
    ///
    /// 1. Parse every file into a YAML mapping, keyed by kind and UUID.
    /// 2. Create or update each record's own attributes, with no relationships.
    /// 3. Resolve relationships, now that every record exists to be pointed at.
    ///
    /// A single-pass importer would have to either sort the files by dependency
    /// or re-visit unresolved links; splitting the passes means a to-do can name
    /// its parent regardless of which file the zip happened to list first.
    func importEntries(_ entries: [Zip.Entry], strategy: Strategy = .merge) -> ImportReport {
        var report = ImportReport()

        // MARK: Pass 1 — parse
        var parsed: [ArchiveFormat.RecordKind: [(uuid: UUID, value: YAMLValue)]] = [:]

        for entry in entries {
            let path = entry.path

            if isManifest(path) {
                readManifest(entry, into: &report)
                continue
            }

            // Skip zip metadata directories that macOS and other tools add.
            if path.hasPrefix("__MACOSX/") || path.hasSuffix(".DS_Store") { continue }
            guard let kind = kind(forPath: path) else {
                // A file somewhere the importer does not recognize. Worth
                // telling the user about, but not worth failing over.
                if path.hasSuffix(".yaml") || path.hasSuffix(".yml") {
                    report.skippedFiles.append(path)
                }
                continue
            }

            guard let text = String(data: entry.data, encoding: .utf8)
                ?? String(data: entry.data, encoding: .isoLatin1)
            else {
                report.skippedFiles.append(path)
                continue
            }

            let value = YAMLParser.parse(text)
            guard let mapping = value.mappingValue, !mapping.isEmpty else {
                report.skippedFiles.append(path)
                continue
            }

            // Prefer the UUID inside the file; fall back to the filename, which
            // is where it would be if the field were dropped in an edit.
            guard let uuid = value.value(forAnyKey: Key.uuid)?.uuidValue
                ?? uuidFromFilename(path)
            else {
                report.skippedFiles.append(path)
                report.warnings.append("‘\(path)’ has no usable identifier.")
                continue
            }

            parsed[kind, default: []].append((uuid: uuid, value: value))
            noteUnknownFields(in: mapping, kind: kind, report: &report)
        }

        if parsed.isEmpty {
            report.warnings.append("The archive contained no records this version can read.")
            return report
        }

        if case .replace = strategy {
            deleteEverything(report: &report)
        }

        // MARK: Pass 2 — attributes
        var spaces: [UUID: Space] = [:]
        var todos: [UUID: Todo] = [:]

        for record in parsed[.space] ?? [] {
            spaces[record.uuid] = upsertSpace(record.uuid, record.value, report: &report)
        }
        for record in parsed[.todo] ?? [] {
            todos[record.uuid] = upsertTodo(record.uuid, record.value, report: &report)
        }

        // MARK: Pass 3 — relationships
        for record in parsed[.todo] ?? [] {
            guard let todo = todos[record.uuid] else { continue }
            link(todo, from: record.value, spaces: spaces, todos: todos, report: &report)
        }

        for record in parsed[.reminder] ?? [] {
            upsertReminder(record.uuid, record.value, todos: todos, report: &report)
        }

        for record in parsed[.summary] ?? [] {
            upsertSummary(record.uuid, record.value, report: &report)
        }

        // Placement drives which list a to-do appears in, and it is derived from
        // relationships that only exist as of pass 3 — so it is recomputed here
        // rather than trusting the bucket the archive carried.
        for todo in todos.values {
            todo.refileForCurrentScheduling()
        }

        breakParentCycles(in: todos, report: &report)

        do {
            try context.save()
        } catch {
            AppLog.data.error("Import save failed: \(error, privacy: .public)")
            report.warnings.append("Some changes could not be saved: \(error.localizedDescription)")
        }

        AppLog.data.info(
            "Imported \(report.totalCreated, privacy: .public) new, \(report.totalUpdated, privacy: .public) updated"
        )
        return report
    }

    // MARK: Manifest

    private func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == "manifest.yaml" || name == "manifest.yml"
    }

    /// Read the manifest for its version stamp.
    ///
    /// A version this build does not know is recorded and otherwise ignored —
    /// the per-field leniency below is what actually handles the difference, and
    /// refusing a newer archive outright would defeat the purpose.
    private func readManifest(_ entry: Zip.Entry, into report: inout ImportReport) {
        guard let text = String(data: entry.data, encoding: .utf8) else { return }
        let manifest = YAMLParser.parse(text)

        report.archiveVersion = manifest
            .value(forAnyKey: ["formatVersion", "version", "schemaVersion"])?
            .intValue

        if let version = report.archiveVersion, version > ArchiveFormat.currentVersion {
            report.warnings.append(
                "This archive was written by a newer version of TODO (format \(version)). "
                + "Anything this version doesn't recognize was skipped."
            )
        }
    }

    private func kind(forPath path: String) -> ArchiveFormat.RecordKind? {
        let components = path.split(separator: "/").map(String.init)
        // Search every component, so an archive that was unzipped and re-zipped
        // inside a wrapping folder still resolves.
        for component in components.dropLast() {
            if let kind = ArchiveFormat.RecordKind.forDirectory(component) { return kind }
        }
        return nil
    }

    private func uuidFromFilename(_ path: String) -> UUID? {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return UUID(uuidString: base)
    }

    // MARK: Records

    private func upsertSpace(
        _ uuid: UUID,
        _ value: YAMLValue,
        report: inout ImportReport
    ) -> Space {
        let space: Space
        if let existing = existingSpace(uuid) {
            space = existing
            report.updatedSpaces += 1
        } else {
            space = Space()
            space.uuid = uuid
            context.insert(space)
            report.createdSpaces += 1
        }

        // Each field independently falls back to what the model already holds,
        // which for a new record is its default. That is the whole forgiveness
        // contract, applied one field at a time.
        if let name = value.value(forAnyKey: Key.Space.name)?.stringValue {
            space.name = name
        }
        if let symbol = value.value(forAnyKey: Key.Space.symbolName)?.stringValue,
           !symbol.isEmpty {
            space.symbolName = symbol
        }
        if let color = value.value(forAnyKey: Key.Space.colorHex)?.stringValue,
           let normalized = normalizeHex(color) {
            space.colorHex = normalized
        }
        if let sortIndex = value.value(forAnyKey: Key.Space.sortIndex)?.intValue {
            space.sortIndex = sortIndex
        }
        if let hidden = value.value(forAnyKey: Key.Space.isHiddenByFocus)?.boolValue {
            space.isHiddenByFocus = hidden
        }
        if let createdAt = value.value(forAnyKey: Key.createdAt)?.dateValue {
            space.createdAt = createdAt
        }

        return space
    }

    private func upsertTodo(
        _ uuid: UUID,
        _ value: YAMLValue,
        report: inout ImportReport
    ) -> Todo {
        let todo: Todo
        if let existing = existingTodo(uuid) {
            todo = existing
            report.updatedTodos += 1
        } else {
            todo = Todo()
            todo.uuid = uuid
            context.insert(todo)
            report.createdTodos += 1
        }

        if let title = value.value(forAnyKey: Key.Todo.title)?.stringValue {
            todo.title = title
        }
        if let notes = value.value(forAnyKey: Key.Todo.notes)?.stringValue {
            todo.notes = notes
        }
        if let summary = value.value(forAnyKey: Key.Todo.notesSummary)?.stringValue {
            todo.notesSummary = summary
        }

        // An unrecognized enum case keeps the default rather than failing — a
        // state added in a later version reads as `open` here, which is wrong
        // but recoverable, unlike losing the to-do.
        if let raw = value.value(forAnyKey: Key.Todo.state)?.stringValue {
            if let state = CompletionState(rawValue: raw.lowercased()) {
                todo.state = state
            } else if let legacy = legacyState(raw) {
                todo.state = legacy
            } else {
                report.warnings.append("Unknown state ‘\(raw)’ on a to-do; imported as open.")
            }
        }
        if let raw = value.value(forAnyKey: Key.Todo.bucket)?.stringValue,
           let bucket = Bucket(rawValue: raw.lowercased()) {
            todo.bucket = bucket
        }

        if let assigned = value.value(forAnyKey: Key.Todo.assignedDate)?.dateValue {
            todo.assignedDate = assigned
        }
        if let hasTime = value.value(forAnyKey: Key.Todo.assignedHasTime)?.boolValue {
            todo.assignedHasTime = hasTime
        }
        if let due = value.value(forAnyKey: Key.Todo.dueDate)?.dateValue {
            todo.dueDate = due
        }
        if let dueHasTime = value.value(forAnyKey: Key.Todo.dueHasTime)?.boolValue {
            todo.dueHasTime = dueHasTime
        }
        // Normalized to the start of its week on the way in. A hand-written or
        // foreign archive can carry any instant here, and the list predicates
        // compare anchors for equality — an unnormalized value would match no
        // week and the row would be invisible in both lists.
        if let weekAnchor = value.value(forAnyKey: Key.Todo.weekAnchor)?.dateValue {
            todo.weekAnchor = WeekMath.startOfWeek(containing: weekAnchor)
        }
        if let duration = value.value(forAnyKey: Key.Todo.duration)?.doubleValue,
           duration > 0 {
            todo.duration = duration
        }

        if let isProject = value.value(forAnyKey: Key.Todo.isProject)?.boolValue {
            todo.isProject = isProject
        }
        if let color = value.value(forAnyKey: Key.Todo.colorHex)?.stringValue {
            todo.colorHex = normalizeHex(color)
        }
        if let sortIndex = value.value(forAnyKey: Key.Todo.sortIndex)?.intValue {
            todo.sortIndex = sortIndex
        }
        if let isNew = value.value(forAnyKey: Key.Todo.isNew)?.boolValue {
            todo.isNew = isNew
        }
        if let placement = value.value(forAnyKey: Key.Todo.lastViewedPlacement)?.stringValue {
            todo.lastViewedPlacement = placement
        }
        if let imported = value.value(forAnyKey: Key.Todo.importedFromReminders)?.boolValue {
            todo.importedFromReminders = imported
        }
        if let sourceID = value.value(forAnyKey: Key.Todo.sourceReminderID)?.stringValue {
            todo.sourceReminderID = sourceID
        }

        if let createdAt = value.value(forAnyKey: Key.createdAt)?.dateValue {
            todo.createdAt = createdAt
        }
        if let modifiedAt = value.value(forAnyKey: Key.Todo.modifiedAt)?.dateValue {
            todo.modifiedAt = modifiedAt
        }
        if let resolvedAt = value.value(forAnyKey: Key.Todo.resolvedAt)?.dateValue {
            todo.resolvedAt = resolvedAt
        }

        applyRecurrence(from: value, to: todo, report: &report)

        // A resolved to-do with no resolution date would sort oddly in the
        // Logbook, so one is synthesized from what the record does carry.
        if todo.state.isResolved && todo.resolvedAt == nil {
            todo.resolvedAt = todo.modifiedAt
        }

        return todo
    }

    /// Read a recurrence schedule off a record, if it carries one.
    ///
    /// The mode is what makes a record a template, so an unrecognized mode
    /// leaves the to-do non-recurring rather than half-configured: a rule with
    /// a frequency but no mode would be a schedule the engine could never run.
    private func applyRecurrence(
        from value: YAMLValue,
        to todo: Todo,
        report: inout ImportReport
    ) {
        guard let modeRaw = value.value(forAnyKey: Key.Todo.recurrenceMode)?.stringValue else {
            return
        }
        guard let mode = RecurrenceMode(rawValue: modeRaw) else {
            report.warnings.append(
                "Unknown repeat mode ‘\(modeRaw)’ on a to-do; it was imported without a schedule."
            )
            return
        }

        var rule = RecurrenceRule(mode: mode)

        if let raw = value.value(forAnyKey: Key.Todo.recurrenceFrequency)?.stringValue,
           let frequency = RecurrenceFrequency(rawValue: raw) {
            rule.frequency = frequency
        }
        if let interval = value.value(forAnyKey: Key.Todo.recurrenceInterval)?.intValue {
            rule.interval = interval
        }
        if let raw = value.value(forAnyKey: Key.Todo.recurrenceWeekdays)?.stringValue {
            rule.weekdays = Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        if let day = value.value(forAnyKey: Key.Todo.recurrenceDayOfMonth)?.intValue {
            rule.dayOfMonth = day
        }
        if let minutes = value.value(forAnyKey: Key.Todo.recurrenceTimeOfDayMinutes)?.intValue {
            rule.timeOfDayMinutes = minutes
        }
        if let endDate = value.value(forAnyKey: Key.Todo.recurrenceEndDate)?.dateValue {
            rule.endDate = endDate
        }
        if let raw = value.value(forAnyKey: Key.Todo.recurrenceStatus)?.stringValue,
           let status = RecurrenceStatus(rawValue: raw) {
            rule.status = status
        }

        // Normalized on the way in: an archive can be hand-edited, and an
        // interval of zero would make the engine's date walk non-terminating.
        todo.recurrenceRule = rule.normalized()

        if let next = value.value(forAnyKey: Key.Todo.recurrenceNextDate)?.dateValue {
            todo.recurrenceNextDate = next
        }

        // A template carries no one-off scheduling of its own. Applied on the
        // way in because an archive can predate that rule — or be hand-edited —
        // and a template arriving with a stale due date reads as an overdue
        // task rather than a schedule. Runs after `recurrenceNextDate` is read
        // so the archive's own seed wins over the assigned date.
        todo.clearScheduleForTemplate()
    }

    /// Attach a to-do to its space and parent.
    ///
    /// A reference naming a record not in the archive is dropped and counted:
    /// the to-do lands in the Inbox instead of vanishing, which is recoverable
    /// by hand in a way a missing record is not.
    private func link(
        _ todo: Todo,
        from value: YAMLValue,
        spaces: [UUID: Space],
        todos: [UUID: Todo],
        report: inout ImportReport
    ) {
        if let spaceUUID = value.value(forAnyKey: Key.Todo.space)?.uuidValue {
            if let space = spaces[spaceUUID] ?? existingSpace(spaceUUID) {
                todo.space = space
            } else {
                report.danglingReferences.append("space \(spaceUUID.uuidString)")
            }
        }

        if let parentUUID = value.value(forAnyKey: Key.Todo.parent)?.uuidValue {
            if parentUUID == todo.uuid {
                // A record naming itself as its parent would make every
                // ancestor walk non-terminating.
                report.warnings.append("A to-do listed itself as its own parent; the link was dropped.")
            } else if let parent = todos[parentUUID] ?? existingTodo(parentUUID) {
                todo.parent = parent
                // A child follows its parent's space when it named none of its
                // own, matching `move(toParent:)`.
                if todo.space == nil { todo.space = parent.space }
            } else {
                report.danglingReferences.append("parent \(parentUUID.uuidString)")
            }
        }

        if let templateUUID = value.value(forAnyKey: Key.Todo.recurrenceTemplate)?.uuidValue {
            if templateUUID == todo.uuid {
                // A record naming itself as its own template would be both a
                // series and one of its own occurrences.
                report.warnings.append(
                    "A to-do listed itself as its own repeat template; the link was dropped."
                )
            } else if let template = todos[templateUUID] ?? existingTodo(templateUUID) {
                todo.recurrenceTemplate = template
            } else {
                report.danglingReferences.append("recurrence template \(templateUUID.uuidString)")
            }
        }
    }

    private func upsertReminder(
        _ uuid: UUID,
        _ value: YAMLValue,
        todos: [UUID: Todo],
        report: inout ImportReport
    ) {
        let reminder: Reminder
        if let existing = existingReminder(uuid) {
            reminder = existing
            report.updatedReminders += 1
        } else {
            reminder = Reminder()
            reminder.uuid = uuid
            context.insert(reminder)
            report.createdReminders += 1
        }

        if let raw = value.value(forAnyKey: Key.Reminder.kind)?.stringValue,
           let kind = ReminderKind(rawValue: raw) {
            reminder.kind = kind
        }
        if let fireDate = value.value(forAnyKey: Key.Reminder.fireDate)?.dateValue {
            reminder.fireDate = fireDate
        }
        if let latitude = value.value(forAnyKey: Key.Reminder.latitude)?.doubleValue {
            reminder.latitude = latitude
        }
        if let longitude = value.value(forAnyKey: Key.Reminder.longitude)?.doubleValue {
            reminder.longitude = longitude
        }
        if let radius = value.value(forAnyKey: Key.Reminder.radius)?.doubleValue, radius > 0 {
            reminder.radius = radius
        }
        if let placeName = value.value(forAnyKey: Key.Reminder.placeName)?.stringValue {
            reminder.placeName = placeName
        }
        if let raw = value.value(forAnyKey: Key.Reminder.trigger)?.stringValue,
           let trigger = LocationTrigger(rawValue: raw) {
            reminder.trigger = trigger
        }
        if let isActive = value.value(forAnyKey: Key.Reminder.isActive)?.boolValue {
            reminder.isActive = isActive
        }
        if let createdAt = value.value(forAnyKey: Key.createdAt)?.dateValue {
            reminder.createdAt = createdAt
        }

        if let todoUUID = value.value(forAnyKey: Key.Reminder.todo)?.uuidValue {
            if let todo = todos[todoUUID] ?? existingTodo(todoUUID) {
                reminder.todo = todo
            } else {
                report.danglingReferences.append("to-do \(todoUUID.uuidString)")
            }
        }
    }

    /// Summaries are a cache, so they are only ever inserted, never merged.
    ///
    /// A stale one costs a single regeneration; reconciling them would be effort
    /// spent on data the app is happy to rebuild.
    private func upsertSummary(
        _ uuid: UUID,
        _ value: YAMLValue,
        report: inout ImportReport
    ) {
        guard existingSummary(uuid) == nil else { return }

        var summary = AISummary()
        summary.quickSummary = value.value(forAnyKey: Key.Summary.quickSummary)?.stringValue
        if let detailed = value.value(forAnyKey: Key.Summary.detailedSummary) {
            summary.detailedSummary = detailed.stringList
        }

        var fingerprint = SummaryFingerprint()
        if let stored = value.value(forKey: "fingerprint") {
            fingerprint.instructions = stored.value(forKey: "instructions")?.stringValue ?? ""
            fingerprint.user = stored.value(forKey: "user")?.stringList ?? []
            fingerprint.weather = stored.value(forKey: "weather")?.stringList ?? []
            fingerprint.todos = stored.value(forKey: "todos")?.stringList ?? []
            fingerprint.events = stored.value(forKey: "events")?.stringList ?? []
        }

        let record = SavedAISummary(summary: summary, fingerprint: fingerprint)
        record.uuid = uuid
        if let generatedOn = value.value(forAnyKey: Key.Summary.generatedOn)?.dateValue {
            record.generatedOn = generatedOn
        }
        context.insert(record)
        report.createdSummaries += 1
    }

    // MARK: Integrity

    /// Break any parent chain that loops back on itself.
    ///
    /// `Todo.ancestors` walks with a visited set and so survives a cycle, but
    /// every other consumer — subtask rendering, completion cascade — recurses
    /// freely. An archive assembled by hand can easily describe A→B→A, so the
    /// cycle is cut here, at the one place bad data enters the store.
    private func breakParentCycles(in todos: [UUID: Todo], report: inout ImportReport) {
        for todo in todos.values {
            var seen: Set<UUID> = [todo.uuid]
            var current = todo

            while let parent = current.parent {
                if !seen.insert(parent.uuid).inserted {
                    current.parent = nil
                    current.refileForCurrentScheduling()
                    report.warnings.append(
                        "A circular parent link was found and broken at ‘\(current.title)’."
                    )
                    break
                }
                current = parent
            }
        }
    }

    /// Empty the store ahead of a `.replace` import.
    ///
    /// Deletes fetched objects one at a time rather than calling
    /// `context.delete(model:)`. The batch form compiles to a store-level
    /// delete that does not see rows still pending insert in this context, so
    /// anything created and not yet saved — which on a fresh launch is
    /// everything — survived the "replace" and reappeared alongside the
    /// archive's records.
    ///
    /// Spaces and to-dos cascade to their children, but every entity is cleared
    /// explicitly so a future model not reachable by cascade is still removed.
    private func deleteEverything(report: inout ImportReport) {
        do {
            for reminder in (try? context.fetch(FetchDescriptor<Reminder>())) ?? [] {
                context.delete(reminder)
            }
            for todo in (try? context.fetch(FetchDescriptor<Todo>())) ?? [] {
                context.delete(todo)
            }
            for space in (try? context.fetch(FetchDescriptor<Space>())) ?? [] {
                context.delete(space)
            }
            for summary in (try? context.fetch(FetchDescriptor<SavedAISummary>())) ?? [] {
                context.delete(summary)
            }
            try context.save()
        } catch {
            AppLog.data.error("Replace-import could not clear the store: \(error, privacy: .public)")
            report.warnings.append(
                "The existing data could not be fully cleared, so the archive was merged into it instead."
            )
        }
    }

    // MARK: Lookups

    /// Fetch by UUID.
    ///
    /// A predicate-based fetch per record rather than one bulk fetch: SwiftData
    /// resolves these against its in-memory row cache, and it keeps records
    /// inserted earlier in this same import visible to later ones.
    private func existingSpace(_ uuid: UUID) -> Space? {
        var descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func existingTodo(_ uuid: UUID) -> Todo? {
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func existingReminder(_ uuid: UUID) -> Reminder? {
        var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func existingSummary(_ uuid: UUID) -> SavedAISummary? {
        var descriptor = FetchDescriptor<SavedAISummary>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Field tolerance

    /// Note fields the archive carried that this build has no home for.
    ///
    /// Purely informational — it is how a user finds out that importing a newer
    /// export dropped something, instead of discovering it later by its absence.
    private func noteUnknownFields(
        in mapping: [String: YAMLValue],
        kind: ArchiveFormat.RecordKind,
        report: inout ImportReport
    ) {
        let known = Self.knownFields[kind] ?? []
        for key in mapping.keys where !known.contains(Self.normalizeKey(key)) {
            report.unknownFields.insert("\(kind.rawValue).\(key)")
        }
    }

    /// Normalize a key the same way `YAMLValue.value(forKey:)` does, so a
    /// spelling the readers resolve is a spelling this does not warn about.
    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Every field the readers understand, and the spellings each accepts.
    ///
    /// The readers above take their key lists from here rather than writing
    /// them inline, and `knownFields` is derived from the same table. That is
    /// what keeps "a spelling the importer accepts" and "a spelling the
    /// importer does not warn about" from being two lists that can disagree —
    /// when they did, adding a field meant a correct import that nonetheless
    /// told the user the field had been ignored.
    ///
    /// The first spelling in each list is the one the exporter writes.
    enum Key {
        static let uuid = ["uuid", "id", "identifier"]
        static let createdAt = ["createdAt", "created"]

        enum Space {
            static let name = ["name", "title"]
            static let symbolName = ["symbolName", "symbol", "icon"]
            static let colorHex = ["colorHex", "color"]
            static let sortIndex = ["sortIndex", "order", "position"]
            static let isHiddenByFocus = ["isHiddenByFocus", "hiddenByFocus"]

            static let all = [uuid, name, symbolName, colorHex, sortIndex,
                              isHiddenByFocus, createdAt]
        }

        enum Todo {
            static let title = ["title", "name", "text"]
            static let notes = ["notes", "note", "body", "description"]
            static let notesSummary = ["notesSummary", "summary"]
            static let state = ["state", "status", "completionState"]
            static let bucket = ["bucket", "list"]
            static let assignedDate = ["assignedDate", "scheduledDate", "startDate", "date"]
            static let assignedHasTime = ["assignedHasTime", "hasTime"]
            static let dueDate = ["dueDate", "deadline", "due"]
            static let dueHasTime = ["dueHasTime"]
            static let weekAnchor = ["weekAnchor", "weekStart", "scheduledWeek"]
            static let duration = ["duration", "length"]
            static let isProject = ["isProject", "project"]
            static let colorHex = ["colorHex", "color"]
            static let sortIndex = ["sortIndex", "order", "position"]
            static let isNew = ["isNew", "new"]
            static let lastViewedPlacement = ["lastViewedPlacement"]
            static let importedFromReminders = ["importedFromReminders"]
            static let sourceReminderID = ["sourceReminderID", "sourceReminderId"]
            static let modifiedAt = ["modifiedAt", "modified", "updatedAt"]
            static let resolvedAt = ["resolvedAt", "completedAt"]
            static let space = ["space", "spaceID", "spaceUUID"]
            static let parent = ["parent", "parentID", "parentUUID"]

            static let recurrenceMode = ["recurrenceMode", "repeatMode"]
            static let recurrenceFrequency = ["recurrenceFrequency", "repeatFrequency", "frequency"]
            static let recurrenceInterval = ["recurrenceInterval", "repeatInterval", "interval"]
            static let recurrenceWeekdays = ["recurrenceWeekdays", "repeatWeekdays", "weekdays"]
            static let recurrenceDayOfMonth = ["recurrenceDayOfMonth", "dayOfMonth"]
            static let recurrenceTimeOfDayMinutes = ["recurrenceTimeOfDayMinutes", "recurrenceTime"]
            static let recurrenceEndDate = ["recurrenceEndDate", "repeatUntil"]
            static let recurrenceStatus = ["recurrenceStatus", "repeatStatus"]
            static let recurrenceNextDate = ["recurrenceNextDate", "nextOccurrence"]
            static let recurrenceTemplate = [
                "recurrenceTemplate", "recurrenceTemplateID", "template",
            ]

            static let all = [uuid, title, notes, notesSummary, state, bucket,
                              assignedDate, assignedHasTime, dueDate, dueHasTime,
                              weekAnchor, duration, isProject, colorHex, sortIndex, isNew,
                              lastViewedPlacement, importedFromReminders,
                              sourceReminderID, createdAt, modifiedAt, resolvedAt,
                              space, parent,
                              recurrenceMode, recurrenceFrequency, recurrenceInterval,
                              recurrenceWeekdays, recurrenceDayOfMonth,
                              recurrenceTimeOfDayMinutes, recurrenceEndDate,
                              recurrenceStatus, recurrenceNextDate, recurrenceTemplate]
        }

        enum Reminder {
            static let kind = ["kind", "type"]
            static let fireDate = ["fireDate", "date", "when"]
            static let latitude = ["latitude", "lat"]
            static let longitude = ["longitude", "lon", "lng"]
            static let radius = ["radius"]
            static let placeName = ["placeName", "place", "location"]
            static let trigger = ["trigger", "locationTrigger"]
            static let isActive = ["isActive", "active"]
            static let todo = ["todo", "todoID", "todoUUID"]

            static let all = [uuid, kind, fireDate, latitude, longitude, radius,
                              placeName, trigger, isActive, createdAt, todo]
        }

        enum Summary {
            static let generatedOn = ["generatedOn", "generated", "createdAt"]
            static let quickSummary = ["quickSummary", "quick"]
            static let detailedSummary = ["detailedSummary", "detailed", "details"]
            static let fingerprint = ["fingerprint"]

            static let all = [uuid, generatedOn, quickSummary, detailedSummary, fingerprint]
        }
    }

    /// Spellings that raise no "unrecognized field" warning, derived from the
    /// same table the readers use and normalized the way `value(forKey:)` is.
    private static let knownFields: [ArchiveFormat.RecordKind: Set<String>] = {
        func normalize(_ groups: [[String]]) -> Set<String> {
            Set(groups.flatMap { $0 }.map(normalizeKey))
        }
        return [
            .space: normalize(Key.Space.all),
            .todo: normalize(Key.Todo.all),
            .reminder: normalize(Key.Reminder.all),
            .summary: normalize(Key.Summary.all),
        ]
    }()

    /// State names used by earlier builds and by other to-do apps.
    private func legacyState(_ raw: String) -> CompletionState? {
        switch raw.lowercased().filter({ $0.isLetter }) {
        case "done", "complete", "finished", "closed": .completed
        case "canceled", "dropped", "abandoned": .cancelled
        case "inprogress", "doing", "active": .started
        case "todo", "pending", "incomplete", "new": .open
        default: nil
        }
    }

    /// Accept a color with or without the leading `#`, and expand the 3-digit
    /// shorthand, so a hand-written `#f00` still lands as a valid color.
    private func normalizeHex(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()

        let isHex = cleaned.allSatisfy { $0.isHexDigit }
        guard isHex else { return nil }

        switch cleaned.count {
        case 6: return "#\(cleaned)"
        case 3: return "#" + cleaned.flatMap { [$0, $0] }
        // An 8-digit value carries alpha the model has no field for; the color
        // is kept and the alpha dropped.
        case 8: return "#\(cleaned.prefix(6))"
        default: return nil
        }
    }
}
