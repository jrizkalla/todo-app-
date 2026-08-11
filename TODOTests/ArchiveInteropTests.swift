import Testing
import Foundation
import SwiftData
import UniformTypeIdentifiers
@testable import TODO

/// Checks that an exported archive is a real zip, not merely one this app's own
/// reader happens to accept.
///
/// Writing the container by hand makes "it round-trips" too weak a guarantee: a
/// symmetric bug in the writer and reader would pass every other test while
/// producing a file Finder refuses to open. These tests write the archive to
/// disk and unpack it with the system's own unzip, which is the tool the user is
/// actually going to reach for.
@MainActor
struct ArchiveInteropTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.appContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Run a command, returning its exit status and stdout.
    ///
    /// `Process` is macOS-only, so these tests are skipped on a simulator run.
    #if os(macOS)
    private func run(_ launchPath: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The system's unzip must accept the archive and verify every CRC.
    @Test func systemUnzipAcceptsTheArchive() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        context.insert(space)
        let todo = Todo(title: "Ship it", notes: "# Heading\n\nA body paragraph.", space: space)
        context.insert(todo)
        context.insert(Reminder(kind: .dateTime, fireDate: Date(), todo: todo))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DatabaseExporter(context: context).writeArchive(to: directory)

        // `-t` tests the archive and checks each entry's CRC.
        let (status, output) = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(status == 0, "unzip rejected the archive: \(output)")
        #expect(output.contains("No errors detected"))
    }

    /// Files extracted by the system tool must hold the exported YAML, which is
    /// what makes the export readable outside the app.
    @Test func extractedFilesAreReadableYAML() throws {
        let context = try makeContext()
        context.insert(Todo(title: "Buy milk", notes: "Semi-skimmed.\n\nTwo pints."))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DatabaseExporter(context: context).writeArchive(to: directory)
        let extracted = directory.appending(path: "extracted")

        let (status, output) = try run("/usr/bin/unzip", ["-q", url.path, "-d", extracted.path])
        #expect(status == 0, "unzip failed: \(output)")

        let todosDirectory = extracted.appending(path: "todos")
        let files = try FileManager.default.contentsOfDirectory(atPath: todosDirectory.path)
        let firstFile = try #require(files.first)
        let contents = try String(
            contentsOf: todosDirectory.appending(path: firstFile),
            encoding: .utf8
        )

        #expect(contents.contains("title: Buy milk"))
        #expect(contents.contains("Semi-skimmed."))

        // And the extracted file must still parse back to the same values.
        let parsed = YAMLParser.parse(contents)
        #expect(parsed.value(forKey: "title")?.stringValue == "Buy milk")
        #expect(parsed.value(forKey: "notes")?.stringValue == "Semi-skimmed.\n\nTwo pints.")
    }

    /// An archive rebuilt by the system's zip must import cleanly — the path a
    /// user takes when they unzip an export, edit a file, and zip it again.
    @Test func importsAnArchiveRebuiltBySystemZip() throws {
        let source = try makeContext()
        source.insert(Todo(title: "Original title"))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DatabaseExporter(context: source).writeArchive(to: directory)
        let extracted = directory.appending(path: "extracted")
        _ = try run("/usr/bin/unzip", ["-q", url.path, "-d", extracted.path])

        // Edit a record by hand, exactly as a user would.
        let todosDirectory = extracted.appending(path: "todos")
        let files = try FileManager.default.contentsOfDirectory(atPath: todosDirectory.path)
        let firstFile = try #require(files.first)
        let recordURL = todosDirectory.appending(path: firstFile)
        let edited = try String(contentsOf: recordURL, encoding: .utf8)
            .replacingOccurrences(of: "title: Original title", with: "title: Edited by hand")
        try edited.write(to: recordURL, atomically: true, encoding: .utf8)

        let rebuilt = directory.appending(path: "rebuilt.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", rebuilt.path, "."]
        process.currentDirectoryURL = extracted
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let destination = try makeContext()
        let report = try DatabaseImporter(context: destination)
            .importArchive(at: rebuilt, strategy: .merge)

        let imported = (try? destination.fetch(FetchDescriptor<Todo>())) ?? []
        #expect(imported.map(\.title) == ["Edited by hand"])
        #expect(report.skippedFiles.isEmpty)
    }
    #endif

    /// The bytes the Settings buttons actually move.
    ///
    /// `DataExportSection` hands `makeArchive`'s output to `ArchiveDocument` and
    /// reads the file back through `importArchive(at:)`. Those two calls are the
    /// whole of the feature's UI, so exercising them here covers the button
    /// behavior without driving the interface.
    @Test func documentCarriesTheArchiveThroughTheExportPath() throws {
        let context = try makeContext()
        let space = Space(name: "Work")
        context.insert(space)
        context.insert(Todo(title: "Round trip me", space: space))

        let data = try DatabaseExporter(context: context).makeArchive()

        // The document is what `fileExporter` writes; its payload is the bytes
        // it hands to the file wrapper. (`WriteConfiguration` has no public
        // initializer, so the wrapper call itself is not reachable from a test.)
        let written = ArchiveDocument(data: data).data
        #expect(written == data)
        #expect(ArchiveDocument.readableContentTypes.contains(.zip))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: ArchiveFormat.suggestedFilename())
        try written.write(to: url)

        let destination = try makeContext()
        let report = try DatabaseImporter(context: destination).importArchive(at: url)

        let todos = (try? destination.fetch(FetchDescriptor<Todo>())) ?? []
        #expect(todos.map(\.title) == ["Round trip me"])
        #expect(todos.first?.space?.name == "Work")
        #expect(!report.hasProblems)
    }

    /// The exported filename must end in `.zip` so the system opens it with the
    /// right tool and the file picker offers it back on import.
    @Test func suggestedFilenameIsAZip() {
        let name = ArchiveFormat.suggestedFilename(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(name.hasSuffix(".zip"))
        #expect(name.hasPrefix("TODO-Export-"))
    }
}
