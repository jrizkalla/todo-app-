import Testing
import Foundation
import SwiftData
@testable import TODO

/// Export and import against a real store: full round trips, and the schema
/// drift the importer is built to absorb.
@MainActor
struct DatabaseArchiveTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Build an archive from `source` and import it into a fresh store.
    private func roundTrip(from source: ModelContext) throws -> (ModelContext, ImportReport) {
        let data = try DatabaseExporter(context: source).makeArchive()
        let destination = try makeContext()
        let report = try DatabaseImporter(context: destination).importArchive(data)
        return (destination, report)
    }

    private func todos(in context: ModelContext) -> [Todo] {
        (try? context.fetch(FetchDescriptor<Todo>())) ?? []
    }

    private func spaces(in context: ModelContext) -> [Space] {
        (try? context.fetch(FetchDescriptor<Space>())) ?? []
    }

    /// Hand-written record files, wrapped as an archive the importer accepts.
    private func archive(_ files: [String: String]) throws -> Data {
        try ZipWriter.build(
            files.map { Zip.Entry(path: $0.key, data: Data($0.value.utf8)) }
        )
    }

    // MARK: Round trip

    @Test func exportedArchiveHasManifestAndRecords() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        context.insert(space)
        context.insert(Todo(title: "Ship it", space: space))

        let data = try DatabaseExporter(context: context).makeArchive()
        let paths = try ZipReader.entries(in: data).map(\.path)

        #expect(paths.contains(ArchiveFormat.manifestPath))
        #expect(paths.contains { $0.hasPrefix("spaces/") && $0.hasSuffix(".yaml") })
        #expect(paths.contains { $0.hasPrefix("todos/") && $0.hasSuffix(".yaml") })
    }

    @Test func roundTripPreservesTodoFields() throws {
        let context = try makeContext()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = Todo(
            title: "Call **Dana**",
            notes: "# Notes\n\nMulti-line body.",
            dueDate: due,
            dueHasTime: true
        )
        todo.duration = 1800
        todo.sortIndex = 4
        context.insert(todo)

        let (destination, _) = try roundTrip(from: context)
        let imported = try #require(todos(in: destination).first)

        #expect(imported.uuid == todo.uuid)
        #expect(imported.title == "Call **Dana**")
        #expect(imported.notes == "# Notes\n\nMulti-line body.")
        #expect(imported.dueHasTime)
        #expect(imported.duration == 1800)
        #expect(imported.sortIndex == 4)
        // Dates are exported with fractional seconds, so they compare exactly.
        #expect(imported.dueDate == due)
    }

    @Test func roundTripPreservesStateAndResolution() throws {
        let context = try makeContext()
        let done = Todo(title: "Done")
        let cancelled = Todo(title: "Dropped")
        [done, cancelled].forEach(context.insert)
        done.setState(.completed)
        cancelled.setState(.cancelled)

        let (destination, _) = try roundTrip(from: context)
        let imported = todos(in: destination)

        #expect(imported.first { $0.title == "Done" }?.state == .completed)
        #expect(imported.first { $0.title == "Dropped" }?.state == .cancelled)
        #expect(imported.first { $0.title == "Done" }?.resolvedAt != nil)
    }

    @Test func roundTripPreservesSpaceMembership() throws {
        let context = try makeContext()
        let space = Space(name: "Home", symbolName: "house", colorHex: "#FF0000")
        context.insert(space)
        context.insert(Todo(title: "Sweep", space: space))

        let (destination, _) = try roundTrip(from: context)
        let importedSpace = try #require(spaces(in: destination).first)
        let importedTodo = try #require(todos(in: destination).first)

        #expect(importedSpace.name == "Home")
        #expect(importedSpace.symbolName == "house")
        #expect(importedSpace.colorHex == "#FF0000")
        #expect(importedTodo.space?.uuid == space.uuid)
    }

    @Test func roundTripPreservesSubtaskHierarchy() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        [parent, child].forEach(context.insert)
        parent.addSubtask(child)

        let (destination, _) = try roundTrip(from: context)
        let importedParent = try #require(todos(in: destination).first { $0.title == "Parent" })

        #expect(importedParent.subtaskList.count == 1)
        #expect(importedParent.orderedSubtasks.first?.title == "Child")
    }

    @Test func roundTripPreservesReminders() throws {
        let context = try makeContext()
        let todo = Todo(title: "Leave")
        context.insert(todo)
        let reminder = Reminder(
            kind: .location,
            latitude: 51.5,
            longitude: -0.12,
            radius: 250,
            placeName: "Office",
            trigger: .onDeparture,
            todo: todo
        )
        context.insert(reminder)

        let (destination, _) = try roundTrip(from: context)
        let imported = try #require(todos(in: destination).first).reminderList.first

        #expect(imported?.kind == .location)
        #expect(imported?.placeName == "Office")
        #expect(imported?.trigger == .onDeparture)
        #expect(imported?.radius == 250)
    }

    /// A todo's relationships must resolve regardless of which file the reader
    /// happens to reach first — the reason the importer runs in passes.
    @Test func relationshipsResolveRegardlessOfFileOrder() throws {
        let context = try makeContext()
        let parent = Todo(title: "Parent")
        let child = Todo(title: "Child")
        [parent, child].forEach(context.insert)
        parent.addSubtask(child)

        let entries = try ZipReader.entries(
            in: try DatabaseExporter(context: context).makeArchive()
        ).reversed()

        let destination = try makeContext()
        _ = DatabaseImporter(context: destination).importEntries(Array(entries))

        let importedChild = try #require(todos(in: destination).first { $0.title == "Child" })
        #expect(importedChild.parent?.title == "Parent")
    }

    // MARK: Merge and replace

    /// Re-importing the same archive must not duplicate anything.
    @Test func mergeIsIdempotent() throws {
        let context = try makeContext()
        context.insert(Todo(title: "Only one"))

        let data = try DatabaseExporter(context: context).makeArchive()
        let destination = try makeContext()
        let importer = DatabaseImporter(context: destination)

        _ = try importer.importArchive(data)
        let second = try importer.importArchive(data)

        #expect(todos(in: destination).count == 1)
        #expect(second.createdTodos == 0)
        #expect(second.updatedTodos == 1)
    }

    @Test func mergeUpdatesAnExistingRecordInPlace() throws {
        let context = try makeContext()
        let todo = Todo(title: "Original")
        context.insert(todo)
        let data = try DatabaseExporter(context: context).makeArchive()

        todo.title = "Edited locally"
        _ = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).count == 1)
        #expect(todos(in: context).first?.title == "Original")
    }

    @Test func replaceClearsExistingData() throws {
        let source = try makeContext()
        source.insert(Todo(title: "From the archive"))
        let data = try DatabaseExporter(context: source).makeArchive()

        let destination = try makeContext()
        destination.insert(Todo(title: "Should be gone"))

        _ = try DatabaseImporter(context: destination).importArchive(data, strategy: .replace)

        #expect(todos(in: destination).map(\.title) == ["From the archive"])
    }

    // MARK: Forgiveness — schema drift

    /// A field added by a later version must not stop the record importing.
    @Test func importIgnoresUnknownFields() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": """
            uuid: \(uuid.uuidString)
            title: Still imported
            energyLevel: high
            futureFeature:
              nested: value
            """
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.title == "Still imported")
        #expect(report.unknownFields.contains { $0.contains("energyLevel") })
    }

    /// An older export missing most fields takes the model's defaults.
    @Test func importFillsMissingFieldsWithDefaults() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": "uuid: \(uuid.uuidString)\ntitle: Sparse"
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)
        let todo = try #require(todos(in: context).first)

        #expect(todo.title == "Sparse")
        #expect(todo.state == .open)
        #expect(todo.bucket == .inbox)
        #expect(todo.notes.isEmpty)
        #expect(todo.isProject == false)
    }

    /// Values of the wrong type are coerced where the meaning is unambiguous.
    @Test func importCoercesMistypedValues() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": """
            uuid: \(uuid.uuidString)
            title: Coerced
            sortIndex: "12"
            isProject: yes
            duration: "900"
            dueDate: 1800000000
            """
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)
        let todo = try #require(todos(in: context).first)

        #expect(todo.sortIndex == 12)
        #expect(todo.isProject)
        #expect(todo.duration == 900)
        #expect(todo.dueDate == Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// An enum case this build has never seen falls back rather than failing.
    @Test func importFallsBackForUnknownEnumCases() throws {
        let unknown = UUID()
        let legacy = UUID()
        let data = try archive([
            "todos/\(unknown.uuidString).yaml": """
            uuid: \(unknown.uuidString)
            title: Unknown state
            state: deferred
            """,
            "todos/\(legacy.uuidString).yaml": """
            uuid: \(legacy.uuidString)
            title: Legacy state
            state: done
            """,
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        let unknownTodo = try #require(todos(in: context).first { $0.title == "Unknown state" })
        let legacyTodo = try #require(todos(in: context).first { $0.title == "Legacy state" })

        #expect(unknownTodo.state == .open)
        #expect(legacyTodo.state == .completed)
        #expect(report.warnings.contains { $0.contains("deferred") })
    }

    /// Renamed fields resolve through the accepted-spelling lists.
    @Test func importAcceptsRenamedFields() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": """
            id: \(uuid.uuidString)
            name: Renamed fields
            body: The notes
            deadline: 2026-08-11
            order: 5
            """
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)
        let todo = try #require(todos(in: context).first)

        #expect(todo.title == "Renamed fields")
        #expect(todo.notes == "The notes")
        #expect(todo.dueDate != nil)
        #expect(todo.sortIndex == 5)
    }

    /// A record with no `uuid` field is still identified, by its filename.
    @Test func importRecoversIdentifierFromFilename() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": "title: No uuid field"
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.uuid == uuid)
    }

    // MARK: Forgiveness — bad data

    /// One unreadable file must not cost the other records.
    @Test func importSkipsCorruptFilesAndKeepsTheRest() throws {
        let good = UUID()
        let data = try archive([
            "todos/\(good.uuidString).yaml": "uuid: \(good.uuidString)\ntitle: Good",
            "todos/broken.yaml": "\u{FFFD}\u{FFFD} not yaml at all \u{0000}",
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).map(\.title) == ["Good"])
        #expect(!report.skippedFiles.isEmpty)
    }

    /// A link to a record that is not in the archive drops the link, not the
    /// record.
    @Test func importDropsDanglingReferencesButKeepsTheRecord() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": """
            uuid: \(uuid.uuidString)
            title: Orphan
            space: \(UUID().uuidString)
            parent: \(UUID().uuidString)
            """
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)
        let todo = try #require(todos(in: context).first)

        #expect(todo.title == "Orphan")
        #expect(todo.space == nil)
        #expect(todo.parent == nil)
        #expect(report.danglingReferences.count == 2)
        // With no home and no dates, it belongs in the Inbox.
        #expect(todo.bucket == .inbox)
    }

    /// A circular parent chain would make recursive walks non-terminating, so it
    /// is cut at import.
    @Test func importBreaksCircularParentLinks() throws {
        let first = UUID()
        let second = UUID()
        let data = try archive([
            "todos/\(first.uuidString).yaml": """
            uuid: \(first.uuidString)
            title: First
            parent: \(second.uuidString)
            """,
            "todos/\(second.uuidString).yaml": """
            uuid: \(second.uuidString)
            title: Second
            parent: \(first.uuidString)
            """,
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)
        let imported = todos(in: context)

        #expect(imported.count == 2)
        // Exactly one edge is cut, which is what makes the chain finite.
        #expect(imported.filter { $0.parent == nil }.count == 1)
        #expect(report.warnings.contains { $0.contains("circular") })

        for todo in imported {
            #expect(todo.ancestors.count < 2)
        }
    }

    @Test func importRejectsSelfParenting() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": """
            uuid: \(uuid.uuidString)
            title: Self parent
            parent: \(uuid.uuidString)
            """
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.parent == nil)
    }

    /// Colors are normalized rather than rejected.
    @Test func importNormalizesColorValues() throws {
        let withoutHash = UUID()
        let shorthand = UUID()
        let nonsense = UUID()
        let data = try archive([
            "spaces/\(withoutHash.uuidString).yaml":
                "uuid: \(withoutHash.uuidString)\nname: A\ncolorHex: 00FF00",
            "spaces/\(shorthand.uuidString).yaml":
                "uuid: \(shorthand.uuidString)\nname: B\ncolorHex: \"#f00\"",
            "spaces/\(nonsense.uuidString).yaml":
                "uuid: \(nonsense.uuidString)\nname: C\ncolorHex: chartreuse",
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)
        let imported = spaces(in: context)

        #expect(imported.first { $0.name == "A" }?.colorHex == "#00FF00")
        #expect(imported.first { $0.name == "B" }?.colorHex == "#FF0000")
        // Unparseable: keeps the model default rather than storing nonsense.
        #expect(imported.first { $0.name == "C" }?.colorHex == Theme.Palette.defaultSpaceColor)
    }

    // MARK: Forgiveness — archive shape

    /// A missing manifest is not an error; the records are what matter.
    @Test func importWorksWithoutAManifest() throws {
        let uuid = UUID()
        let data = try archive([
            "todos/\(uuid.uuidString).yaml": "uuid: \(uuid.uuidString)\ntitle: No manifest"
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).count == 1)
        #expect(report.archiveVersion == nil)
    }

    /// A newer format version is reported, not refused.
    @Test func importAcceptsANewerFormatVersion() throws {
        let uuid = UUID()
        let data = try archive([
            "manifest.yaml": "formatVersion: 99\napplication: TODO",
            "todos/\(uuid.uuidString).yaml": "uuid: \(uuid.uuidString)\ntitle: From the future",
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.title == "From the future")
        #expect(report.archiveVersion == 99)
        #expect(report.warnings.contains { $0.contains("newer version") })
    }

    /// Re-zipping an export commonly wraps it in a folder and adds macOS
    /// metadata; neither should hide the records.
    @Test func importHandlesWrappedAndDecoratedArchives() throws {
        let uuid = UUID()
        let data = try archive([
            "TODO-Export/todos/\(uuid.uuidString).yaml":
                "uuid: \(uuid.uuidString)\ntitle: Nested",
            "__MACOSX/._manifest.yaml": "junk",
            ".DS_Store": "junk",
        ])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.title == "Nested")
        #expect(report.skippedFiles.isEmpty)
    }

    /// Alternative directory names still map to the right record kind.
    @Test func importAcceptsAlternativeDirectoryNames() throws {
        let uuid = UUID()
        let data = try archive([
            "tasks/\(uuid.uuidString).yaml": "uuid: \(uuid.uuidString)\ntitle: In tasks/"
        ])

        let context = try makeContext()
        _ = try DatabaseImporter(context: context).importArchive(data)

        #expect(todos(in: context).first?.title == "In tasks/")
    }

    /// An archive with nothing recognizable reports it rather than appearing to
    /// succeed silently.
    @Test func importReportsAnEmptyArchive() throws {
        let data = try archive(["readme.txt": "nothing to see"])

        let context = try makeContext()
        let report = try DatabaseImporter(context: context).importArchive(data)

        #expect(report.totalCreated == 0)
        #expect(!report.warnings.isEmpty)
    }

    /// A file that is not a zip is the one case that throws — there is nothing
    /// to be forgiving with.
    @Test func importRejectsANonArchiveFile() throws {
        let context = try makeContext()
        let notAnArchive = Data("just some text".utf8)

        #expect(throws: (any Error).self) {
            try DatabaseImporter(context: context).importArchive(notAnArchive)
        }
    }

    // MARK: Drift guards

    /// The app's own export must not report any field as unrecognized.
    ///
    /// The exporter writes fields, the importer reads them, and a third list
    /// decides which spellings are "known". Nothing in the compiler ties those
    /// together, so this pins the invariant that matters: adding a field to the
    /// exporter without teaching the importer about it produces an archive that
    /// imports while telling the user the field was ignored. That warning is
    /// the one part of the report a user has to be able to trust.
    @Test func selfExportReportsNoUnknownFields() throws {
        let context = try makeContext()

        // Every optional field populated, so no key is absent from the export.
        let space = Space(name: "Work", symbolName: "briefcase", colorHex: "#123456")
        space.isHiddenByFocus = true
        context.insert(space)

        let todo = Todo(
            title: "Everything set",
            notes: "Some notes",
            assignedDate: Date(),
            assignedHasTime: true,
            dueDate: Date(),
            dueHasTime: true,
            space: space
        )
        todo.notesSummary = "A summary"
        todo.duration = 900
        todo.colorHex = "#ABCDEF"
        todo.importedFromReminders = true
        todo.sourceReminderID = "reminder-1"
        todo.resolvedAt = Date()
        context.insert(todo)

        let child = Todo(title: "Child")
        context.insert(child)
        todo.addSubtask(child)

        context.insert(Reminder(
            kind: .location,
            fireDate: Date(),
            latitude: 1, longitude: 2, radius: 50,
            placeName: "Home",
            trigger: .onDeparture,
            todo: todo
        ))

        var fingerprint = SummaryFingerprint()
        fingerprint.instructions = "Be brief"
        fingerprint.todos = ["One"]
        context.insert(SavedAISummary(
            summary: AISummary(quickSummary: "Quick", detailedSummary: ["A", "B"]),
            fingerprint: fingerprint
        ))

        let (_, report) = try roundTrip(from: context)

        #expect(report.unknownFields.isEmpty, "\(report.unknownFields.sorted())")
        #expect(report.skippedFiles.isEmpty)
    }

    /// Every `@Model` in the schema must have somewhere to go in an archive.
    ///
    /// The exporter and importer name their entities one by one, so a model
    /// added to `AppSchema.models` alone would silently be left out of every
    /// export — and, worse, not cleared by a `.replace` import, which claims to
    /// replace everything. This fails the moment the two lists disagree.
    @Test func everyModelHasAnArchiveRecordKind() {
        #expect(ArchiveFormat.RecordKind.allCases.count == AppSchema.models.count)
    }

    // MARK: Scale

    /// A realistic database round-trips intact.
    @Test func roundTripHandlesAFullDatabase() throws {
        let context = try makeContext()

        for spaceIndex in 0..<5 {
            let space = Space(name: "Space \(spaceIndex)", sortIndex: spaceIndex)
            context.insert(space)

            for projectIndex in 0..<4 {
                let project = Todo(title: "Project \(projectIndex)", isProject: true, space: space)
                context.insert(project)

                for taskIndex in 0..<10 {
                    let task = Todo(title: "Task \(spaceIndex)-\(projectIndex)-\(taskIndex)")
                    context.insert(task)
                    project.addSubtask(task)
                }
            }
        }

        let originalCount = todos(in: context).count
        let (destination, report) = try roundTrip(from: context)

        #expect(todos(in: destination).count == originalCount)
        #expect(spaces(in: destination).count == 5)
        #expect(report.skippedFiles.isEmpty)
        #expect(report.danglingReferences.isEmpty)

        let projects = todos(in: destination).filter(\.isProject)
        #expect(projects.count == 20)
        #expect(projects.allSatisfy { $0.subtaskList.count == 10 })
    }
}
