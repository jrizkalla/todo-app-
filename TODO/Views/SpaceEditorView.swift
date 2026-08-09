import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Create or edit a space: name, color, symbol, and its Focus behavior.
///
/// One view serves both flows. Creating goes through a draft rather than
/// inserting an empty `Space` up front, so backing out of the sheet leaves no
/// half-made space behind — the model is only inserted when the user commits.
struct SpaceEditorView: View {
    /// The space being edited, or nil when creating a new one.
    var space: Space?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var symbolName: String = "square.stack"
    @State private var colorHex: String = "#0A84FF"
    @State private var isShowingSymbolPicker = false
    @State private var didLoad = false

    private var store: TodoStore { TodoStore(context: context) }

    private var isCreating: Bool { space == nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accent: Color { Color(hex: colorHex) }

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 16, trailing: 0))
            }

            Section("Name") {
                TextField("Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }

            Section("Color") {
                // The system picker covers the full spectrum, and the palette
                // below it keeps the common choices one tap away.
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { accent },
                        // A color the picker cannot reduce to RGB leaves the
                        // stored value alone rather than resetting it to gray.
                        set: { if let hex = $0.hexString { colorHex = hex } }
                    ),
                    supportsOpacity: false
                )

                ColorSwatchPicker(selection: Binding(
                    get: { colorHex },
                    set: { colorHex = $0 ?? "#8E8E93" }
                ))
            }

            Section("Symbol") {
                Button {
                    isShowingSymbolPicker = true
                } label: {
                    HStack {
                        Label("Symbol", systemImage: symbolName)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text(symbolName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    // Without this the label's own bounds are the hit area, so
                    // only the text and chevron respond — the gaps between them
                    // swallow taps.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !isCreating {
                focusSection
            }
        }
        .formStyle(.grouped)
        .tint(accent)
        .navigationTitle(isCreating ? "New Space" : "Edit Space")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isCreating ? "Add" : "Done") { commit() }
                    .disabled(trimmedName.isEmpty)
                    .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $isShowingSymbolPicker) {
            NavigationStack {
                SymbolPickerView(selection: $symbolName, tint: accent)
            }
        }
        // Loading in `onAppear` rather than `init` keeps the state the single
        // source of truth while the sheet is open; assigning in `init` would be
        // overwritten on every re-render.
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: Header

    /// Large preview of the space as the sidebar will draw it.
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)
                .background {
                    Circle().fill(accent.gradient)
                }
                .animation(Theme.Animation.toggle, value: symbolName)
                .animation(Theme.Animation.toggle, value: colorHex)

            Text(trimmedName.isEmpty ? "New Space" : trimmedName)
                .font(.headline)
                .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Focus

    /// Explains where the Focus association is configured.
    ///
    /// The pairing itself lives in Settings → Focus, because the system owns
    /// that list — an app cannot enumerate or edit the user's Focus modes. All
    /// this app does is expose the space as something a Focus filter can select
    /// and react when one does.
    @ViewBuilder
    private var focusSection: some View {
        Section {
            LabeledContent("Status") {
                Text(space?.isHiddenByFocus == true ? "Hidden" : "Visible")
                    .foregroundStyle(space?.isHiddenByFocus == true ? .secondary : accent)
            }

            #if os(iOS)
            Button {
                openFocusSettings()
            } label: {
                Label("Open Focus Settings", systemImage: "moon.circle")
            }
            #endif
        } header: {
            Text("Focus")
        } footer: {
            Text("In Settings → Focus, choose a Focus, then add TODO under Focus Filters to pick which spaces stay visible while it is on.")
        }
    }

    #if os(iOS)
    private func openFocusSettings() {
        // There is no public deep link to the Focus pane, so this opens the
        // app's own Settings page — the closest reachable point.
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif

    // MARK: Loading and saving

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        if let space {
            name = space.name
            symbolName = space.symbolName
            colorHex = space.colorHex
        } else {
            // Give a new space the next unused palette color, so consecutive
            // spaces do not all come out the same blue.
            let existing = (try? context.fetch(FetchDescriptor<Space>()))?.count ?? 0
            colorHex = Theme.Palette.spaceColors[existing % Theme.Palette.spaceColors.count]
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }

        if let space {
            space.name = trimmedName
            space.symbolName = symbolName
            space.colorHex = colorHex
            store.save()
        } else {
            store.createSpace(name: trimmedName, symbolName: symbolName, colorHex: colorHex)
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Edit space") {
    NavigationStack {
        SpaceEditorView(space: PreviewData.space)
    }
    .previewEnvironment()
}

#Preview("New space") {
    NavigationStack {
        SpaceEditorView(space: nil)
    }
    .previewEnvironment()
}
#endif
