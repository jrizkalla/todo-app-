import SwiftUI

extension View {
    /// A search field that stays hidden until the user pulls the list down.
    ///
    /// Wrapped rather than called directly at each site because the drawer
    /// placement that produces the pull-down behaviour is iOS-only, and both
    /// search surfaces — the sidebar and each list — want exactly the same
    /// treatment. On macOS the field lives in the toolbar, which is where a Mac
    /// user looks for it anyway.
    func pullDownSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(macOS)
        return searchable(text: text, prompt: prompt)
        #else
        return searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: prompt
        )
        #endif
    }

    /// `pullDownSearchable`, but only on platforms that give this view a search
    /// bar of its own.
    ///
    /// The sidebar and the list each carry a search field. On iOS they sit in
    /// two separate navigation bars, so both appear and both work. macOS gives
    /// the whole `NavigationSplitView` a *single* window toolbar, and two
    /// `searchable` modifiers there both try to install the same
    /// `com.apple.SwiftUI.search` toolbar item — which is not a layout quirk
    /// but a hard `NSToolbar` assertion that terminates the app.
    ///
    /// The list's field is the one kept, because it is the more capable of the
    /// two: it scopes to whatever is on screen and it is the only way to search
    /// the Logbook. The sidebar's global search is the one dropped, so on macOS
    /// searching happens in the list pane.
    func columnScopedSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(macOS)
        return self
        #else
        return pullDownSearchable(text: text, prompt: prompt)
        #endif
    }
}

/// One hit in the sidebar's global search.
///
/// Read-only on purpose. The sidebar's results span every list, so a checkbox
/// here would resolve a to-do the user can no longer see in context; tapping
/// takes them to its detail page instead, where the surrounding work is
/// visible. Inside a list, the ordinary editable `TodoRow` is used.
struct SearchResultRow: View {
    let todo: Todo

    var body: some View {
        HStack(spacing: Theme.Metrics.rowSpacing) {
            Image(systemName: todo.isProject ? "list.bullet" : "circle")
                .font(.caption)
                .foregroundStyle(todo.color)

            VStack(alignment: .leading, spacing: 2) {
                InlineMarkdownText(markdown: todo.title.isEmpty ? "Untitled" : todo.title)
                    .lineLimit(1)

                // Where it lives, so two similarly-named to-dos are tellable
                // apart without opening either.
                if let location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// "Space › Project", omitting whichever part the to-do does not have.
    private var location: String? {
        var parts: [String] = []
        if let name = todo.space?.name, !name.isEmpty { parts.append(name) }
        if let parent = todo.parent?.title, !parent.isEmpty { parts.append(parent) }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }
}

/// Shown in place of results when a search matches nothing.
struct SearchEmptyState: View {
    let query: String
    /// Spells out what was searched — "in this list", "in the Logbook" — so a
    /// zero-result search reads as a narrow search rather than as missing data.
    let scopeDescription: String

    var body: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing \(scopeDescription) matches “\(query)”.")
        }
    }
}
