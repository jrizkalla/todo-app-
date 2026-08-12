import SwiftUI

/// The title block at the top of the todo editor, styled after the stock
/// Calendar app's event editor.
///
/// Calendar puts a small gray summary line naming the event and when it
/// happens, with the editable title beneath it in a large weighted font on its
/// own filled field. The same parts read well here because a to-do has the same
/// shape: a schedule and a name.
///
/// Where Calendar draws a colored bar down the left edge, this puts the
/// checkbox: it carries the same color, and unlike the bar it does something —
/// the editor is a place a user will want to tick something off from, and the
/// state picker was otherwise several rows down the form.
struct TodoTitleHeader: View {
    @Binding var title: String
    /// Gray context line above the field — "Review on Aug 9 at 3pm".
    let summary: String
    /// Accent color, resolved from the todo's project or space.
    let accent: Color
    /// Current completion state, drawn in the checkbox.
    var state: CompletionState = .open
    /// Tapping the checkbox. Routed by the caller through the store, so the
    /// subtask rule applies here exactly as it does in the list.
    var onToggle: (() -> Void)?
    var onSelectState: ((CompletionState) -> Void)?

    var focusBinding: FocusState<Bool>.Binding?

    @FocusState private var isFocusedInternal: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Aligned with the summary line above the field rather than with
            // the field itself, which is where the bar it replaced started.
            TodoCheckbox(
                state: state,
                tint: accent,
                onToggle: { onToggle?() },
                onSelect: { onSelectState?($0) }
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(summary)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(accent)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                TextField("Title", text: $title, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    }
                    .modifier(OptionalFocus(binding: focusBinding, fallback: $isFocusedInternal))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Applies the caller's `@FocusState` when one was supplied, and a private one
/// otherwise, so the header works standalone in previews.
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    let fallback: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content.focused(fallback)
        }
    }
}

#if DEBUG
#Preview("Title header") {
    @Previewable @State var title = "Buy Garmin charger"
    @Previewable @State var state = CompletionState.open

    return Form {
        Section {
            TodoTitleHeader(
                title: $title,
                summary: "Buy Garmin charger on Aug 9 at 9:00 AM",
                accent: .blue,
                state: state,
                onToggle: { state = state == .completed ? .open : .completed },
                onSelectState: { state = $0 }
            )
        }
    }
    .formStyle(.grouped)
}
#endif
