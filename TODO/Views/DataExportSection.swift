import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The Settings section for exporting and re-importing the database.
///
/// Kept out of `SettingsView` because it owns a fair amount of state — two file
/// dialogs, a confirmation, and the report of the last import — none of which
/// the rest of Settings has any use for.
struct DataExportSection: View {
    @Environment(\.modelContext) private var context

    @State private var exportDocument: ArchiveDocument?
    @State private var isExporting = false
    @State private var isChoosingFile = false

    /// The archive the user picked, held while they choose how to apply it.
    @State private var pendingImportURL: URL?
    @State private var isChoosingStrategy = false
    @State private var isConfirmingReplace = false

    @State private var isWorking = false
    @State private var report: ImportReport?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button {
                runExport()
            } label: {
                Label("Export All Data…", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)

            Button {
                isChoosingFile = true
            } label: {
                Label("Import from Archive…", systemImage: "square.and.arrow.down")
            }
            .disabled(isWorking)

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.headline)
                        .font(.caption)
                        .foregroundStyle(report.hasProblems ? .primary : .secondary)

                    ForEach(report.details, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Exports every space, to-do, and reminder as a zip of YAML files — readable in any text editor. Importing matches items by identifier, so re-importing the same archive updates your data instead of duplicating it.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: ArchiveFormat.suggestedFilename()
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.zip, .archive, .data]
        ) { result in
            switch result {
            case .success(let url):
                pendingImportURL = url
                isChoosingStrategy = true
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Import Archive",
            isPresented: $isChoosingStrategy,
            titleVisibility: .visible
        ) {
            Button("Merge with My Data") {
                runImport(strategy: .merge)
            }
            Button("Replace Everything…", role: .destructive) {
                isConfirmingReplace = true
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Merging updates items that are already here and adds the rest. Replacing deletes everything first.")
        }
        // Replacing is unrecoverable, so it gets its own confirmation rather
        // than riding on the destructive styling of the choice above.
        .confirmationDialog(
            "Delete all current data?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Delete and Import", role: .destructive) {
                runImport(strategy: .replace)
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Every space, to-do, and reminder on this device will be removed and replaced with the archive's contents. This cannot be undone.")
        }
    }

    // MARK: Actions

    /// Building the archive reads the store, so it stays on the main actor with
    /// the rest of SwiftData. A personal database serializes fast enough that
    /// the dialog opens in the same frame.
    private func runExport() {
        errorMessage = nil
        report = nil

        do {
            let data = try DatabaseExporter(context: context).makeArchive()
            exportDocument = ArchiveDocument(data: data)
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Read the picked file off the main thread, then import on it.
    ///
    /// Only the read is moved: `DatabaseImporter` writes through `ModelContext`
    /// and is `@MainActor` for the same reason every other service here is. The
    /// read is worth moving anyway, because the picker can hand back a file
    /// that iCloud Drive has not downloaded yet — which blocks on the network
    /// for as long as that takes, with the UI frozen behind it.
    private func runImport(strategy: DatabaseImporter.Strategy) {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        errorMessage = nil
        report = nil
        isWorking = true

        Task {
            defer { isWorking = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let needsScope = url.startAccessingSecurityScopedResource()
                    defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url)
                }.value

                report = try DatabaseImporter(context: context).importArchive(data, strategy: strategy)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Carries the exported bytes to `fileExporter`.
///
/// The archive is built in memory before the dialog opens, so this only ever
/// wraps finished data — `init(configuration:)` exists to satisfy the protocol
/// and is not a path the app takes.
struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
