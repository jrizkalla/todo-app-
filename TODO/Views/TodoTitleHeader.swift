import SwiftUI

/// The title block at the top of the todo editor, styled after the stock
/// Calendar app's event editor.
///
/// Calendar puts a colored bar down the left edge, a small gray summary line
/// naming the event and when it happens, and the editable title beneath it in a
/// large weighted font on its own filled field. The same three parts read well
/// here because a to-do has the same shape: a color from its project or space,
/// a schedule, and a name.
struct TodoTitleHeader: View {
    @Binding var title: String
    /// Gray context line above the field — "Review on Aug 9 at 3pm".
    let summary: String
    /// Accent bar color, resolved from the todo's project or space.
    let accent: Color

    var focusBinding: FocusState<Bool>.Binding?

    @FocusState private var isFocusedInternal: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The bar spans the whole block, the way Calendar draws it.
            Capsule()
                .fill(accent)
                .frame(width: 5)

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
    return Form {
        Section {
            TodoTitleHeader(
                title: $title,
                summary: "Buy Garmin charger on Aug 9 at 9:00 AM",
                accent: .blue
            )
        }
    }
    .formStyle(.grouped)
}
#endif
