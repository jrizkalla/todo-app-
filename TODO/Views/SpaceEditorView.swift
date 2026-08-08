import SwiftUI
import SwiftData

/// Rename a space, pick its symbol, and choose its color.
struct SpaceEditorView: View {
    @Bindable var space: Space

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Symbols offered for a space, kept short so the grid stays scannable.
    private let symbols = [
        "square.stack", "briefcase", "house", "person.2", "cart",
        "book", "heart", "airplane", "graduationcap", "wrench.and.screwdriver",
    ]

    private let symbolColumns = [GridItem(.adaptive(minimum: 46), spacing: 10)]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $space.name)
            }

            Section("Color") {
                ColorSwatchPicker(selection: Binding(
                    get: { space.colorHex },
                    // A space always has a color, so nil falls back to gray
                    // rather than meaning "inherit".
                    set: { space.colorHex = $0 ?? "#8E8E93" }
                ))
            }

            Section("Symbol") {
                LazyVGrid(columns: symbolColumns, spacing: 10) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            space.symbolName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 17))
                                .frame(width: 40, height: 40)
                                .foregroundStyle(
                                    space.symbolName == symbol
                                        ? Color(hex: space.colorHex)
                                        : .secondary
                                )
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(space.symbolName == symbol
                                              ? Color(hex: space.colorHex).opacity(0.16)
                                              : Color.secondary.opacity(0.08))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Edit Space")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    TodoStore(context: context).save()
                    dismiss()
                }
            }
        }
    }
}

#if DEBUG
#Preview("Space editor") {
    NavigationStack {
        SpaceEditorView(space: PreviewData.space)
    }
    .previewEnvironment()
}
#endif
