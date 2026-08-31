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

    /// Called instead of `onCommit` when the phrase named a week rather than a
    /// day — "this week", "next week".
    ///
    /// Separate rather than folded into `onCommit` as a date, because the two
    /// mean different things to the store: committing the week's anchor as an
    /// `assignedDate` would pin the to-do to a Sunday nobody typed.
    var onCommitWeek: ((WeekSchedule) -> Void)?

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

                TextField("Type a date — “weds”, “next week”, “aug 10”", text: $text)
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
                // A week phrase reads back as the week, not as the anchor date
                // it carries — echoing "Sunday, Aug 30" at someone who typed
                // "next week" would look like the field had misunderstood.
                parsed.weekSchedule?.label
                    ?? ParsedSuggestion.describe(parsed.date, hasTime: parsed.hasTime),
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

        // A week only commits as a week where the caller can take one. Without
        // a handler the anchor date is the honest fallback: it is inside the
        // week the user named, which is better than dropping the input.
        if let week = parsed.weekSchedule, let onCommitWeek {
            onCommitWeek(week)
        } else {
            onCommit(parsed.date, parsed.hasTime)
        }
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
