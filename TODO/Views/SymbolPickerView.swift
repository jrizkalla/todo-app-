import SwiftUI

/// Searchable SF Symbol browser.
///
/// Presented as a sheet from the space editor. Symbols are grouped by category
/// while the search field is empty and flattened into a single ranked list once
/// the user types, which is the behavior Apple's own symbol pickers use.
struct SymbolPickerView: View {
    @Binding var selection: String
    /// Tint applied to the selected swatch, so the picker previews the symbol in
    /// the color the space actually uses.
    var tint: Color = .accentColor

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 12)]

    /// Search results, or nil while the user has typed nothing — the two modes
    /// render differently rather than one being a special case of the other.
    private var results: [String]? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return SFSymbolCatalog.search(trimmed)
    }

    var body: some View {
        ScrollView {
            if let results {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results, id: \.self) { symbol in
                            cell(symbol)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(SFSymbolCatalog.categories) { category in
                        Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(category.names, id: \.self) { symbol in
                                    cell(symbol)
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            Label(category.name, systemImage: category.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .searchable(text: $query, prompt: "Search symbols")
        .navigationTitle("Choose a Symbol")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func cell(_ symbol: String) -> some View {
        let isSelected = symbol == selection

        return Button {
            selection = symbol
            dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 52, height: 52)
                .foregroundStyle(isSelected ? .white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? tint : Color.secondary.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#if DEBUG
#Preview("Symbol picker") {
    @Previewable @State var symbol = "briefcase"
    return NavigationStack {
        SymbolPickerView(selection: $symbol, tint: .blue)
    }
}
#endif
