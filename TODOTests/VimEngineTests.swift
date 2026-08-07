import Testing
import Foundation
@testable import TODO

/// Plain buffer so the engine can be tested without AppKit.
final class TestBuffer: VimTextBuffer {
    var vimText: String
    var vimSelectedRange: NSRange

    init(_ text: String, caret: Int = 0) {
        self.vimText = text
        self.vimSelectedRange = NSRange(location: caret, length: 0)
    }

    var caret: Int { vimSelectedRange.location }
}

/// Vim mode behavior for the macOS notes editor.
struct VimEngineTests {

    /// Feed a sequence of keystrokes.
    private func type(_ keys: String, into buffer: TestBuffer, engine: VimEngine) {
        for character in keys {
            _ = engine.handle(key: String(character), in: buffer)
        }
    }

    private let escape = "\u{1B}"

    // MARK: Modes

    @Test func startsInNormalMode() {
        #expect(VimEngine().mode == .normal)
    }

    @Test func iEntersInsertMode() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello")
        type("i", into: buffer, engine: engine)
        #expect(engine.mode == .insert)
    }

    /// In insert mode the engine declines keys so the text view types them.
    @Test func insertModePassesKeysThrough() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello")
        type("i", into: buffer, engine: engine)
        #expect(engine.handle(key: "x", in: buffer) == false)
    }

    @Test func escapeReturnsToNormalMode() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello")
        type("i", into: buffer, engine: engine)
        _ = engine.handle(key: escape, in: buffer)
        #expect(engine.mode == .normal)
    }

    /// Normal mode swallows unmapped letters instead of inserting them.
    @Test func normalModeDoesNotInsertText() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello")
        type("zq", into: buffer, engine: engine)
        #expect(buffer.vimText == "hello")
    }

    @Test func vTogglesVisualMode() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello")
        type("v", into: buffer, engine: engine)
        #expect(engine.mode == .visual)
        type("v", into: buffer, engine: engine)
        #expect(engine.mode == .normal)
    }

    // MARK: Motions

    @Test func hAndLMoveByCharacter() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 2)
        type("l", into: buffer, engine: engine)
        #expect(buffer.caret == 3)
        type("h", into: buffer, engine: engine)
        #expect(buffer.caret == 2)
    }

    /// A numeric prefix repeats the motion.
    @Test func countPrefixRepeatsMotion() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 0)
        type("3l", into: buffer, engine: engine)
        #expect(buffer.caret == 3)
    }

    @Test func wJumpsToNextWord() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world again", caret: 0)
        type("w", into: buffer, engine: engine)
        #expect(buffer.caret == 6)
    }

    @Test func bJumpsToPreviousWord() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 6)
        type("b", into: buffer, engine: engine)
        #expect(buffer.caret == 0)
    }

    @Test func zeroGoesToLineStartAndDollarToEnd() {
        let engine = VimEngine()
        let buffer = TestBuffer("first\nsecond line", caret: 9)

        type("0", into: buffer, engine: engine)
        #expect(buffer.caret == 6)

        type("$", into: buffer, engine: engine)
        #expect(buffer.caret == 17)
    }

    @Test func gGoesToEndAndGgToStart() {
        let engine = VimEngine()
        let buffer = TestBuffer("one\ntwo\nthree", caret: 0)

        type("G", into: buffer, engine: engine)
        #expect(buffer.caret == 13)

        type("gg", into: buffer, engine: engine)
        #expect(buffer.caret == 0)
    }

    /// Vertical motion keeps the column where the target line is long enough.
    @Test func jAndKKeepColumn() {
        let engine = VimEngine()
        let buffer = TestBuffer("abcdef\nghijkl", caret: 3)

        type("j", into: buffer, engine: engine)
        #expect(buffer.caret == 10)

        type("k", into: buffer, engine: engine)
        #expect(buffer.caret == 3)
    }

    /// Moving to a shorter line clamps to that line's end.
    @Test func verticalMotionClampsToShortLine() {
        let engine = VimEngine()
        let buffer = TestBuffer("abcdefgh\nxy", caret: 7)
        type("j", into: buffer, engine: engine)
        #expect(buffer.caret == 11)
    }

    // MARK: Editing

    @Test func xDeletesCharacterUnderCaret() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 0)
        type("x", into: buffer, engine: engine)
        #expect(buffer.vimText == "ello")
    }

    @Test func countedXDeletesSeveral() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 0)
        type("3x", into: buffer, engine: engine)
        #expect(buffer.vimText == "lo")
    }

    @Test func ddDeletesWholeLine() {
        let engine = VimEngine()
        let buffer = TestBuffer("one\ntwo\nthree", caret: 4)
        type("dd", into: buffer, engine: engine)
        #expect(buffer.vimText == "one\nthree")
    }

    @Test func dwDeletesWord() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 0)
        type("dw", into: buffer, engine: engine)
        #expect(buffer.vimText == "world")
    }

    /// `cw` deletes the word and drops into insert mode.
    @Test func cwDeletesWordAndEntersInsert() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 0)
        type("cw", into: buffer, engine: engine)
        #expect(buffer.vimText == "world")
        #expect(engine.mode == .insert)
    }

    @Test func dollarDeleteRemovesToLineEnd() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 5)
        type("D", into: buffer, engine: engine)
        #expect(buffer.vimText == "hello")
    }

    /// Yank leaves the text alone and fills the register for `p`.
    @Test func yyThenPDuplicatesLine() {
        let engine = VimEngine()
        let buffer = TestBuffer("one\ntwo", caret: 0)

        type("yy", into: buffer, engine: engine)
        #expect(buffer.vimText == "one\ntwo")

        type("p", into: buffer, engine: engine)
        #expect(buffer.vimText == "one\none\ntwo")
    }

    /// `dd` then `p` moves a line rather than losing it.
    @Test func ddThenPMovesLine() {
        let engine = VimEngine()
        let buffer = TestBuffer("one\ntwo", caret: 0)

        type("dd", into: buffer, engine: engine)
        #expect(buffer.vimText == "two")

        type("p", into: buffer, engine: engine)
        #expect(buffer.vimText == "two\none\n")
    }

    @Test func oOpensLineBelowAndEntersInsert() {
        let engine = VimEngine()
        let buffer = TestBuffer("one", caret: 0)
        type("o", into: buffer, engine: engine)
        #expect(buffer.vimText == "one\n")
        #expect(engine.mode == .insert)
    }

    @Test func capitalOOpensLineAbove() {
        let engine = VimEngine()
        let buffer = TestBuffer("one", caret: 0)
        type("O", into: buffer, engine: engine)
        #expect(buffer.vimText == "\none")
        #expect(engine.mode == .insert)
    }

    // MARK: Insert positioning

    @Test func aMovesCaretForwardBeforeInsert() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 0)
        type("a", into: buffer, engine: engine)
        #expect(buffer.caret == 1)
        #expect(engine.mode == .insert)
    }

    @Test func capitalIGoesToLineStart() {
        let engine = VimEngine()
        let buffer = TestBuffer("  hello", caret: 5)
        type("I", into: buffer, engine: engine)
        #expect(buffer.caret == 0)
        #expect(engine.mode == .insert)
    }

    @Test func capitalAGoesToLineEnd() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 0)
        type("A", into: buffer, engine: engine)
        #expect(buffer.caret == 5)
        #expect(engine.mode == .insert)
    }

    // MARK: Visual mode

    @Test func visualSelectionDeletes() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello world", caret: 0)

        type("v", into: buffer, engine: engine)
        type("lll", into: buffer, engine: engine)
        type("d", into: buffer, engine: engine)

        #expect(buffer.vimText == "o world")
        #expect(engine.mode == .normal)
    }

    // MARK: Safety

    /// Motions at the buffer edges must not run past the ends.
    @Test func motionsClampAtBufferBounds() {
        let engine = VimEngine()
        let buffer = TestBuffer("ab", caret: 0)

        type("hhhh", into: buffer, engine: engine)
        #expect(buffer.caret == 0)

        type("llllll", into: buffer, engine: engine)
        #expect(buffer.caret == 2)
    }

    /// Editing commands on an empty buffer must not crash or corrupt state.
    @Test func commandsOnEmptyBufferAreSafe() {
        let engine = VimEngine()
        let buffer = TestBuffer("", caret: 0)

        type("xdd", into: buffer, engine: engine)
        type("wbG", into: buffer, engine: engine)

        #expect(buffer.vimText == "")
        #expect(buffer.caret == 0)
    }

    /// Pasting with nothing yanked is a no-op.
    @Test func pasteWithEmptyRegisterDoesNothing() {
        let engine = VimEngine()
        let buffer = TestBuffer("hello", caret: 0)
        type("p", into: buffer, engine: engine)
        #expect(buffer.vimText == "hello")
    }
}
