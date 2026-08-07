import Foundation

/// Vim editing mode.
enum VimMode: Equatable {
    case normal
    case insert
    case visual
}

/// The subset of a text buffer the vim engine operates on.
///
/// Keeping this a protocol lets the engine be driven by `NSTextView` in the app
/// and by a plain struct in tests, with no AppKit dependency in the logic.
protocol VimTextBuffer: AnyObject {
    var vimText: String { get set }
    /// Caret offset in UTF-16 units, matching `NSRange`.
    var vimSelectedRange: NSRange { get set }
}

/// A minimal vim mode implementation for the macOS text fields.
///
/// Scope is deliberately the everyday core — motions, mode switches, and the
/// common operators — rather than full vim. Anything it does not recognize is
/// passed back to the text view unchanged.
final class VimEngine {
    private(set) var mode: VimMode = .normal

    /// Start of the visual-mode selection anchor.
    private var visualAnchor: Int?
    /// Buffer for multi-key sequences such as `dd`, `gg`, `dw`.
    private var pendingOperator: Character?
    /// Numeric prefix, e.g. the `3` in `3j`.
    private var countBuffer: String = ""

    /// Yanked/deleted text for `p`.
    private var register: String = ""
    /// Whether the register holds whole lines, which changes how `p` pastes.
    private var registerIsLinewise = false

    // MARK: Key handling

    /// Handle a keystroke.
    ///
    /// - Returns: `true` if the engine consumed the key, `false` to let the
    ///   text view handle it normally (which is how insert mode types text).
    func handle(key: String, modifiers: VimModifiers = [], in buffer: any VimTextBuffer) -> Bool {
        // Escape always returns to normal mode.
        if key == "\u{1B}" {
            if mode != .normal {
                mode = .normal
                visualAnchor = nil
                clampCaret(in: buffer)
            }
            resetPending()
            return true
        }

        switch mode {
        case .insert:
            // Insert mode is ordinary typing; only Escape is special.
            return false
        case .normal, .visual:
            return handleCommand(key: key, modifiers: modifiers, in: buffer)
        }
    }

    private func handleCommand(key: String, modifiers: VimModifiers, in buffer: any VimTextBuffer) -> Bool {
        guard let character = key.first, key.count == 1 else { return false }

        // Digits build a count prefix ("0" is a motion unless a count is open).
        if character.isNumber, !(character == "0" && countBuffer.isEmpty) {
            countBuffer.append(character)
            return true
        }

        let count = max(Int(countBuffer) ?? 1, 1)

        // A pending operator means this key is its motion (`dw`, `dd`, `gg`).
        if let pending = pendingOperator {
            defer { resetPending() }
            return applyOperator(pending, motion: character, count: count, in: buffer)
        }

        switch character {
        // MARK: Mode switches
        case "i":
            mode = .insert
            resetPending()
            return true
        case "a":
            moveCaret(by: 1, in: buffer)
            mode = .insert
            resetPending()
            return true
        case "I":
            setCaret(to: lineStart(of: caret(in: buffer), in: buffer.vimText), in: buffer)
            mode = .insert
            resetPending()
            return true
        case "A":
            setCaret(to: lineEnd(of: caret(in: buffer), in: buffer.vimText), in: buffer)
            mode = .insert
            resetPending()
            return true
        case "o":
            openLine(below: true, in: buffer)
            mode = .insert
            resetPending()
            return true
        case "O":
            openLine(below: false, in: buffer)
            mode = .insert
            resetPending()
            return true
        case "v":
            if mode == .visual {
                mode = .normal
                visualAnchor = nil
            } else {
                mode = .visual
                visualAnchor = caret(in: buffer)
            }
            resetPending()
            return true

        // MARK: Motions
        case "h":
            moveCaret(by: -count, in: buffer); resetPending(); return true
        case "l":
            moveCaret(by: count, in: buffer); resetPending(); return true
        case "j":
            moveLine(by: count, in: buffer); resetPending(); return true
        case "k":
            moveLine(by: -count, in: buffer); resetPending(); return true
        case "w":
            setCaret(to: wordForward(from: caret(in: buffer), count: count, in: buffer.vimText), in: buffer)
            resetPending(); return true
        case "b":
            setCaret(to: wordBackward(from: caret(in: buffer), count: count, in: buffer.vimText), in: buffer)
            resetPending(); return true
        case "0":
            setCaret(to: lineStart(of: caret(in: buffer), in: buffer.vimText), in: buffer)
            resetPending(); return true
        case "$":
            setCaret(to: lineEnd(of: caret(in: buffer), in: buffer.vimText), in: buffer)
            resetPending(); return true
        case "G":
            setCaret(to: (buffer.vimText as NSString).length, in: buffer)
            resetPending(); return true

        // MARK: Operators
        case "d", "c", "y":
            if mode == .visual {
                applyToVisualSelection(character, in: buffer)
                return true
            }
            pendingOperator = character
            countBuffer = ""
            return true
        case "x":
            deleteRange(NSRange(location: caret(in: buffer), length: min(count, remaining(in: buffer))), in: buffer)
            resetPending(); return true
        case "D":
            let start = caret(in: buffer)
            deleteRange(NSRange(location: start, length: lineEnd(of: start, in: buffer.vimText) - start), in: buffer)
            resetPending(); return true
        case "p":
            paste(in: buffer)
            resetPending(); return true
        case "g":
            pendingOperator = "g"
            return true

        default:
            resetPending()
            // Unhandled keys are swallowed in normal mode so they do not insert
            // text, which is what vim does.
            return mode == .normal
        }
    }

    /// Apply `dd`, `dw`, `cw`, `yy`, `gg`, and friends.
    private func applyOperator(
        _ op: Character,
        motion: Character,
        count: Int,
        in buffer: any VimTextBuffer
    ) -> Bool {
        // `gg` jumps to the top of the buffer.
        if op == "g" {
            if motion == "g" { setCaret(to: 0, in: buffer) }
            return true
        }

        let start = caret(in: buffer)
        let text = buffer.vimText
        var range: NSRange
        var linewise = false

        switch motion {
        case op:
            // Doubled operator acts on whole lines: `dd`, `yy`, `cc`.
            let lineStartIndex = lineStart(of: start, in: text)
            var end = lineEnd(of: start, in: text)
            // Take the trailing newline too, so the line fully disappears.
            if end < (text as NSString).length { end += 1 }
            range = NSRange(location: lineStartIndex, length: end - lineStartIndex)
            linewise = true
        case "w":
            range = NSRange(location: start, length: wordForward(from: start, count: count, in: text) - start)
        case "b":
            let target = wordBackward(from: start, count: count, in: text)
            range = NSRange(location: target, length: start - target)
        case "$":
            range = NSRange(location: start, length: lineEnd(of: start, in: text) - start)
        case "0":
            let target = lineStart(of: start, in: text)
            range = NSRange(location: target, length: start - target)
        default:
            return true
        }

        guard range.length > 0, range.location >= 0 else { return true }

        register = (text as NSString).substring(with: range)
        registerIsLinewise = linewise

        switch op {
        case "y":
            // Yank leaves the text alone; the caret moves to the range start.
            setCaret(to: range.location, in: buffer)
        case "d":
            deleteRange(range, in: buffer)
        case "c":
            deleteRange(range, in: buffer)
            mode = .insert
        default:
            break
        }
        return true
    }

    /// `d`/`c`/`y` while a visual selection is active.
    private func applyToVisualSelection(_ op: Character, in buffer: any VimTextBuffer) {
        guard let anchor = visualAnchor else { return }
        let start = min(anchor, caret(in: buffer))
        let end = max(anchor, caret(in: buffer))

        // Vim's visual selection includes the character under the caret, so the
        // range runs one past the caret's offset.
        let length = min(end - start + 1, (buffer.vimText as NSString).length - start)
        guard length > 0 else { return }
        let range = NSRange(location: start, length: length)

        register = (buffer.vimText as NSString).substring(with: range)
        registerIsLinewise = false

        switch op {
        case "y":
            setCaret(to: start, in: buffer)
        case "d":
            deleteRange(range, in: buffer)
        case "c":
            deleteRange(range, in: buffer)
            mode = .insert
        default:
            break
        }

        if op != "c" { mode = .normal }
        visualAnchor = nil
    }

    // MARK: Editing primitives

    private func deleteRange(_ range: NSRange, in buffer: any VimTextBuffer) {
        let nsText = buffer.vimText as NSString
        guard range.location >= 0, NSMaxRange(range) <= nsText.length, range.length > 0 else { return }

        buffer.vimText = nsText.replacingCharacters(in: range, with: "")
        setCaret(to: range.location, in: buffer)
    }

    private func paste(in buffer: any VimTextBuffer) {
        guard !register.isEmpty else { return }
        let nsText = buffer.vimText as NSString

        if registerIsLinewise {
            // Linewise paste drops the text on the line below the caret.
            var insertion = lineEnd(of: caret(in: buffer), in: buffer.vimText)
            var payload = register

            if insertion < nsText.length {
                // Step past the newline so the text lands on its own line.
                insertion += 1
            } else if insertion > 0 {
                // At the very end of a buffer with no trailing newline, the
                // separator has to come from the paste itself.
                payload = "\n" + register
            }

            buffer.vimText = nsText.replacingCharacters(
                in: NSRange(location: insertion, length: 0),
                with: payload
            )
            setCaret(to: insertion, in: buffer)
        } else {
            let insertion = min(caret(in: buffer) + 1, nsText.length)
            buffer.vimText = nsText.replacingCharacters(in: NSRange(location: insertion, length: 0), with: register)
            setCaret(to: insertion + (register as NSString).length - 1, in: buffer)
        }
    }

    private func openLine(below: Bool, in buffer: any VimTextBuffer) {
        let text = buffer.vimText
        let nsText = text as NSString
        let insertion = below
            ? min(lineEnd(of: caret(in: buffer), in: text), nsText.length)
            : lineStart(of: caret(in: buffer), in: text)

        buffer.vimText = nsText.replacingCharacters(
            in: NSRange(location: insertion, length: 0),
            with: below ? "\n" : "\n"
        )
        setCaret(to: below ? insertion + 1 : insertion, in: buffer)
    }

    // MARK: Caret helpers

    private func caret(in buffer: any VimTextBuffer) -> Int {
        buffer.vimSelectedRange.location
    }

    private func remaining(in buffer: any VimTextBuffer) -> Int {
        max((buffer.vimText as NSString).length - caret(in: buffer), 0)
    }

    private func setCaret(to location: Int, in buffer: any VimTextBuffer) {
        let clamped = min(max(location, 0), (buffer.vimText as NSString).length)
        buffer.vimSelectedRange = NSRange(location: clamped, length: 0)
    }

    private func clampCaret(in buffer: any VimTextBuffer) {
        setCaret(to: caret(in: buffer), in: buffer)
    }

    private func moveCaret(by delta: Int, in buffer: any VimTextBuffer) {
        setCaret(to: caret(in: buffer) + delta, in: buffer)
    }

    /// Move vertically, keeping the column where possible.
    private func moveLine(by delta: Int, in buffer: any VimTextBuffer) {
        let text = buffer.vimText
        let current = caret(in: buffer)
        let column = current - lineStart(of: current, in: text)

        var target = current
        for _ in 0..<abs(delta) {
            if delta > 0 {
                let end = lineEnd(of: target, in: text)
                guard end < (text as NSString).length else { break }
                target = end + 1
            } else {
                let start = lineStart(of: target, in: text)
                guard start > 0 else { break }
                target = lineStart(of: start - 1, in: text)
            }
        }

        let newLineStart = lineStart(of: target, in: text)
        let newLineEnd = lineEnd(of: target, in: text)
        setCaret(to: min(newLineStart + column, newLineEnd), in: buffer)
    }

    private func resetPending() {
        pendingOperator = nil
        countBuffer = ""
    }

    // MARK: Text scanning

    func lineStart(of location: Int, in text: String) -> Int {
        let nsText = text as NSString
        var index = min(max(location, 0), nsText.length)
        while index > 0, nsText.character(at: index - 1) != 0x0A { index -= 1 }
        return index
    }

    func lineEnd(of location: Int, in text: String) -> Int {
        let nsText = text as NSString
        var index = min(max(location, 0), nsText.length)
        while index < nsText.length, nsText.character(at: index) != 0x0A { index += 1 }
        return index
    }

    /// Start of the nth next word.
    func wordForward(from location: Int, count: Int, in text: String) -> Int {
        let nsText = text as NSString
        var index = min(max(location, 0), nsText.length)

        for _ in 0..<count {
            // Skip the current word, then the whitespace after it.
            while index < nsText.length, !isWhitespace(nsText.character(at: index)) { index += 1 }
            while index < nsText.length, isWhitespace(nsText.character(at: index)) { index += 1 }
        }
        return index
    }

    /// Start of the nth previous word.
    func wordBackward(from location: Int, count: Int, in text: String) -> Int {
        let nsText = text as NSString
        var index = min(max(location, 0), nsText.length)

        for _ in 0..<count {
            while index > 0, isWhitespace(nsText.character(at: index - 1)) { index -= 1 }
            while index > 0, !isWhitespace(nsText.character(at: index - 1)) { index -= 1 }
        }
        return index
    }

    private func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// Modifier flags, mirrored so the engine does not depend on AppKit.
struct VimModifiers: OptionSet {
    let rawValue: Int
    static let control = VimModifiers(rawValue: 1 << 0)
    static let option = VimModifiers(rawValue: 1 << 1)
    static let command = VimModifiers(rawValue: 1 << 2)
    static let shift = VimModifiers(rawValue: 1 << 3)
}

#if os(macOS)
import AppKit

extension VimEngine {
    /// Bridge an `NSEvent` into the platform-independent entry point.
    func handle(event: NSEvent, in textView: NSTextView) -> Bool {
        guard let characters = event.charactersIgnoringModifiers else { return false }

        // Command-key shortcuts belong to the app, not the editor.
        if event.modifierFlags.contains(.command) { return false }

        var modifiers: VimModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }

        return handle(key: characters, modifiers: modifiers, in: textView)
    }
}

/// Lets `VimEngine` drive an `NSTextView` directly.
extension NSTextView: VimTextBuffer {
    var vimText: String {
        get { string }
        set { string = newValue }
    }

    var vimSelectedRange: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
}
#endif
