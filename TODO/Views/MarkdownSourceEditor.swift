import SwiftUI

/// Plain-text editor for markdown source.
///
/// On macOS this wraps an `NSTextView` so vim bindings can intercept keys; on
/// other platforms it is a plain `TextEditor`, since the spec scopes vim to
/// macOS.
struct MarkdownSourceEditor: View {
    @Binding var text: String
    var vimBindingsEnabled: Bool = false

    var body: some View {
        #if os(macOS)
        VimTextEditor(text: $text, vimEnabled: vimBindingsEnabled)
        #else
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
        #endif
    }
}

#if os(macOS)
import AppKit

/// `NSTextView` bridge that optionally routes keys through `VimEngine`.
struct VimTextEditor: NSViewRepresentable {
    @Binding var text: String
    var vimEnabled: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = VimCapableTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)

        if let vimView = textView as? VimCapableTextView {
            vimView.coordinator = context.coordinator
        }

        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.vimEnabled = vimEnabled
        if let vimView = textView as? VimCapableTextView {
            vimView.vimEnabled = vimEnabled
        }

        // Only write back when the model diverges, so typing does not reset the
        // insertion point.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(location: min(selection.location, text.utf16.count), length: 0)
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, vimEnabled: vimEnabled)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var vimEnabled: Bool
        let engine = VimEngine()

        init(text: Binding<String>, vimEnabled: Bool) {
            self._text = text
            self.vimEnabled = vimEnabled
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

/// `NSTextView` that gives `VimEngine` first refusal on key events.
final class VimCapableTextView: NSTextView {
    var vimEnabled = false
    weak var coordinator: VimTextEditor.Coordinator?

    override func keyDown(with event: NSEvent) {
        guard vimEnabled, let coordinator else {
            super.keyDown(with: event)
            return
        }

        if coordinator.engine.handle(event: event, in: self) {
            // Engine consumed the key; keep the caret block-styled in normal
            // mode so the current mode is visible.
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    /// Block caret in normal mode, thin caret in insert mode.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vimEnabled, coordinator?.engine.mode == .normal else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        var blockRect = rect
        blockRect.size.width = max(rect.width, 7)
        super.drawInsertionPoint(in: blockRect, color: color.withAlphaComponent(0.55), turnedOn: flag)
    }
}
#endif

#if DEBUG
private struct MarkdownSourceEditorPreviewHost: View {
    @State private var text = """
    # Notes

    Some **bold** text with `inline code`.

    - first
    - second
    """
    var vimEnabled: Bool = false

    var body: some View {
        MarkdownSourceEditor(text: $text, vimBindingsEnabled: vimEnabled)
            .frame(minHeight: 200)
            .padding()
    }
}

#Preview("Source editor") {
    MarkdownSourceEditorPreviewHost()
}

#Preview("Vim bindings") {
    // macOS only; elsewhere this renders the plain editor.
    MarkdownSourceEditorPreviewHost(vimEnabled: true)
}
#endif
