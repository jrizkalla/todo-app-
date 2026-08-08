import SwiftUI

/// Chips offering to turn text found in a title into a real property.
///
/// Placement differs by platform per the spec: above the keyboard on iOS and
/// iPadOS (via `.safeAreaInset`, which tracks the keyboard automatically), and
/// at the bottom of the window on macOS. The bar itself is the same view; only
/// the attachment point changes, handled by `suggestionBar(_:onAccept:)`.
struct SuggestionBar: View {
    let suggestions: [ParsedSuggestion]
    let onAccept: (ParsedSuggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onAccept(suggestion)
                    } label: {
                        Label(suggestion.label, systemImage: suggestion.symbolName)
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                Capsule().fill(Color.accentColor.opacity(0.14))
                            }
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // Hidden rather than absent when empty, so the enclosing inset keeps a
        // stable identity while the user types.
        .background(suggestions.isEmpty ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
        .animation(Theme.Animation.suggestion, value: suggestions)
    }
}

extension View {
    /// Attach the suggestion bar at the platform-appropriate edge.
    ///
    /// The inset container is always present, collapsing to zero height when
    /// there is nothing to suggest. Adding and removing the inset itself would
    /// restructure the view tree on each keystroke, which makes the text field
    /// being typed into lose focus.
    func suggestionBar(
        _ suggestions: [ParsedSuggestion],
        onAccept: @escaping (ParsedSuggestion) -> Void
    ) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            SuggestionBar(suggestions: suggestions, onAccept: onAccept)
                .frame(height: suggestions.isEmpty ? 0 : nil)
                .opacity(suggestions.isEmpty ? 0 : 1)
                .clipped()
                .allowsHitTesting(!suggestions.isEmpty)
                .animation(Theme.Animation.suggestion, value: suggestions.isEmpty)
        }
    }
}

#Preview {
    let parser = TitleParser()
    return VStack {
        Spacer()
        Text("Editor")
        Spacer()
    }
    .suggestionBar(parser.suggestions(for: "Clean car tomorrow 30m")) { _ in }
}
