import SwiftUI

/// A text field that reads a typed date phrase and echoes back what it made of
/// it.
///
/// Sits at the top of the scheduling panel so the panel can be driven entirely
/// from the keyboard: Cmd+S opens it with this field focused, the user types
/// "weds" or "aug 10", and Return commits. The same `DatePhraseParser` behind
/// the title chips does the reading, so a phrase that works in a title works
/// here too.
struct QuickDateField: View {
    /// Called with the parsed date when the user commits.
    let onCommit: (Date, _ hasTime: Bool) -> Void

    /// Focus on appear, since the whole point is typing without reaching for
    /// the mouse.
    var focusesOnAppear = true

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var parsed: DatePhraseMatch? {
        DatePhraseParser().parseWhole(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("Type a date — “weds”, “aug 10”, “in 3 days”", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(commit)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            }

            // Reads back the interpretation before the user commits, so a
            // phrase that parsed to something unintended is visible rather than
            // being discovered later on the wrong day.
            interpretation
        }
        .onAppear {
            if focusesOnAppear { isFocused = true }
        }
    }

    @ViewBuilder
    private var interpretation: some View {
        if let parsed {
            Label(
                ParsedSuggestion.describe(parsed.date, hasTime: parsed.hasTime),
                systemImage: "return"
            )
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .transition(.opacity)
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Label("No date recognized", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else {
            // Holds the row's height so the panel does not jump as the
            // interpretation appears and disappears under the cursor.
            Text(" ").font(.caption).hidden()
        }
    }

    private func commit() {
        guard let parsed else { return }
        onCommit(parsed.date, parsed.hasTime)
        text = ""
    }
}

#if DEBUG
#Preview("Quick date field") {
    VStack(alignment: .leading, spacing: 20) {
        QuickDateField(onCommit: { _, _ in }, focusesOnAppear: false)
    }
    .padding()
    .frame(width: 340)
}
#endif
