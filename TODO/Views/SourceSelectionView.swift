import SwiftUI
import EventKit

/// Picks which Reminders lists or calendars the app reads from.
///
/// Presented as its own page rather than inline in Settings, because the list
/// is as long as the user's account has calendars. Rows are checkmarks with a
/// colour dot, matching Calendar.app and Reminders.app, rather than toggles.
struct SourceSelectionView: View {
    let title: String
    /// Explanation shown under the list, describing what selecting does.
    let footer: String
    let sources: [EKCalendar]
    /// The system's default, selected when the user has made no choice.
    let defaultIdentifier: String?

    /// Selected identifiers. `nil` means "not chosen", which shows the default
    /// as selected without writing a choice until the user actually picks.
    @Binding var selection: [String]?

    private var effectiveSelection: Set<String> {
        if let selection { return Set(selection) }
        return Set([defaultIdentifier].compactMap { $0 })
    }

    private var allSelected: Bool {
        !sources.isEmpty && effectiveSelection.count == sources.count
    }

    var body: some View {
        List {
            Section {
                ForEach(sources, id: \.calendarIdentifier) { source in
                    row(for: source)
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    // Both write an explicit array, so "none" survives as a
                    // real choice rather than falling back to the default.
                    selection = allSelected ? [] : sources.map(\.calendarIdentifier)
                }
            }
        }
    }

    private func row(for source: EKCalendar) -> some View {
        let isSelected = effectiveSelection.contains(source.calendarIdentifier)

        return Button {
            toggle(source.calendarIdentifier)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)

                Circle()
                    .fill(Color(hex: CalendarEventStore.hexString(from: source.cgColor)))
                    .frame(width: 11, height: 11)

                Text(source.title)
                    .foregroundStyle(.primary)

                Spacer()

                if source.calendarIdentifier == defaultIdentifier {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Flip one source, materializing the implicit default into a real
    /// selection on the first change.
    private func toggle(_ identifier: String) {
        var current = effectiveSelection

        if current.contains(identifier) {
            current.remove(identifier)
        } else {
            current.insert(identifier)
        }

        // Preserve the source order rather than a Set's arbitrary one.
        selection = sources
            .map(\.calendarIdentifier)
            .filter { current.contains($0) }
    }
}

extension SourceSelectionView {
    /// Short description of the current selection, for the Settings row.
    static func summary(
        selection: [String]?,
        sources: [EKCalendar],
        defaultIdentifier: String?
    ) -> String {
        guard let selection else {
            guard let defaultIdentifier,
                  let match = sources.first(where: { $0.calendarIdentifier == defaultIdentifier })
            else { return "Default" }
            return match.title
        }

        if selection.isEmpty { return "None" }
        if selection.count == sources.count && !sources.isEmpty { return "All" }
        if selection.count == 1,
           let match = sources.first(where: { $0.calendarIdentifier == selection[0] }) {
            return match.title
        }
        return "\(selection.count) selected"
    }
}

/// Settings row that opens a `SourceSelectionView`.
///
/// The two platforms need different presentations. iOS shows Settings inside a
/// `NavigationStack`, so a push is right there. The Mac's `Settings` scene has
/// no navigation container — a `NavigationLink` there renders as an inert row,
/// which is why the calendar and list pickers were unreachable — so the Mac
/// gets a sheet instead.
struct SourceSelectionRow: View {
    let label: String
    let title: String
    let footer: String
    let sources: [EKCalendar]
    let defaultIdentifier: String?
    @Binding var selection: [String]?

    @State private var isPresented = false

    private var summary: String {
        SourceSelectionView.summary(
            selection: selection,
            sources: sources,
            defaultIdentifier: defaultIdentifier
        )
    }

    private var picker: some View {
        SourceSelectionView(
            title: title,
            footer: footer,
            sources: sources,
            defaultIdentifier: defaultIdentifier,
            selection: $selection
        )
    }

    var body: some View {
        #if os(macOS)
        Button {
            isPresented = true
        } label: {
            LabeledContent(label, value: summary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                picker
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
            .frame(minWidth: 380, minHeight: 420)
        }
        #else
        NavigationLink {
            picker
        } label: {
            LabeledContent(label, value: summary)
        }
        #endif
    }
}
