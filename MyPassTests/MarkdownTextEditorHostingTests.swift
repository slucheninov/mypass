import XCTest
import AppKit
import SwiftUI
@testable import MyPass

/// Hosts the editor under a real SwiftUI state graph. The coordinator-level tests call
/// the editor's methods directly and so cannot see update-pass feedback loops: when
/// toolbar actions travelled as state consumed in `updateNSView`, Undo erased the text
/// and wrapping repeated the markers until the app hung. These tests drive the editor
/// the way the toolbar does (through `MarkdownEditorActions`) and bound the run loop.
@MainActor
final class MarkdownTextEditorHostingTests: XCTestCase {
    struct Host: View {
        @State private var text: String
        @State private var canUndo = false
        @State private var canRedo = false
        let actions: MarkdownEditorActions
        let report: (String, Bool, Bool) -> Void

        init(initial: String, actions: MarkdownEditorActions, report: @escaping (String, Bool, Bool) -> Void) {
            _text = State(initialValue: initial)
            self.actions = actions
            self.report = report
        }

        var body: some View {
            MarkdownTextEditor(text: $text, actions: actions, canUndo: $canUndo, canRedo: $canRedo)
                .frame(width: 300, height: 120)
                .onChange(of: text) { _, _ in report(text, canUndo, canRedo) }
                .onChange(of: canUndo) { _, _ in report(text, canUndo, canRedo) }
                .onChange(of: canRedo) { _, _ in report(text, canUndo, canRedo) }
        }
    }

    private var window: NSWindow!
    private var actions: MarkdownEditorActions!
    private var textView: NSTextView!
    private var text = ""
    private var canUndo = false
    private var canRedo = false

    private func host(initial: String) throws {
        text = initial
        actions = MarkdownEditorActions()
        let hosting = NSHostingView(rootView: Host(initial: initial, actions: actions) { [unowned self] t, u, r in
            text = t; canUndo = u; canRedo = r
        })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns the window; the default would over-release it on close().
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()
        textView = try XCTUnwrap(findTextView(in: hosting))
        window.makeFirstResponder(textView)
    }

    override func tearDown() {
        window?.close(); window = nil; textView = nil; actions = nil
        super.tearDown()
    }

    private func pump(_ turns: Int = 10) {
        for _ in 0..<turns { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    private func type(_ s: String) {
        // A user's keystrokes land in separate run-loop events, which the undo manager
        // folds into separate groups; pumping here does not reproduce that reliably,
        // so each edit is grouped explicitly (as MarkdownTextEditorUndoTests does).
        let manager = textView.undoManager!
        manager.groupsByEvent = false
        textView.breakUndoCoalescing()
        manager.beginUndoGrouping()
        textView.insertText(s, replacementRange: textView.selectedRange())
        manager.endUndoGrouping()
        pump()
    }

    func testWrapAppliesExactlyOnce() throws {
        try host(initial: "abc")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        actions.wrap(prefix: "**", suffix: "**")
        pump()
        XCTAssertEqual(textView.string, "**abc**")
        XCTAssertEqual(text, "**abc**")
    }

    func testToolbarUndoRevertsOneStepAndTypingStillWorks() throws {
        try host(initial: "")
        type("one")
        type(" two")
        XCTAssertEqual(text, "one two")
        actions.undo()
        pump()
        XCTAssertEqual(text, "one")
        XCTAssertEqual(textView.string, "one")
        XCTAssertTrue(canRedo)
        type("!")
        XCTAssertEqual(text, "one!")
    }

    func testToolbarRedoReappliesAndReplaceAllIsOneStep() throws {
        try host(initial: "")
        type("original")
        actions.replaceAll("restored")
        pump()
        XCTAssertEqual(text, "restored")
        actions.undo()
        pump()
        XCTAssertEqual(text, "original")
        actions.redo()
        pump()
        XCTAssertEqual(text, "restored")
    }

    /// Types like a user: real first responder, plain `insertText`, no explicit undo
    /// grouping (the run loop decides how the keystrokes group).
    private func typeLikeUser(_ s: String) {
        for ch in s {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
            pump(1)
        }
        pump()
    }

    func testTypeUndoRedoRoundTripsRepeatedly() throws {
        try host(initial: "")
        typeLikeUser("hello world")
        XCTAssertEqual(text, "hello world")
        XCTAssertTrue(canUndo)
        for round in 1...3 {
            actions.undo()
            pump()
            XCTAssertEqual(textView.string, "", "round \(round) undo")
            XCTAssertEqual(text, "", "round \(round) undo binding")
            XCTAssertFalse(canUndo, "round \(round)")
            XCTAssertTrue(canRedo, "round \(round)")
            actions.redo()
            pump()
            XCTAssertEqual(textView.string, "hello world", "round \(round) redo")
            XCTAssertEqual(text, "hello world", "round \(round) redo binding")
            XCTAssertTrue(canUndo, "round \(round)")
            XCTAssertFalse(canRedo, "round \(round)")
        }
        typeLikeUser("!")
        XCTAssertEqual(text, "hello world!")
    }

    func testKeyboardPathUndoRedoKeepsBindingAndFlagsInSync() throws {
        try host(initial: "")
        typeLikeUser("typed")
        // Cmd-Z / Shift-Cmd-Z dispatch `undo:` / `redo:` down the responder chain to the
        // focused text view (its `undoManager` property is not the delegate-provided one,
        // so the action is sent the way the menu item sends it).
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(textView.tryToPerform(Selector(("undo:")), with: nil))
        pump()
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(text, "")
        XCTAssertFalse(canUndo)
        XCTAssertTrue(canRedo)
        XCTAssertTrue(textView.tryToPerform(Selector(("redo:")), with: nil))
        pump()
        XCTAssertEqual(textView.string, "typed")
        XCTAssertEqual(text, "typed")
        XCTAssertTrue(canUndo)
        XCTAssertFalse(canRedo)
        // Mixed: toolbar undo after a keyboard redo still works.
        actions.undo()
        pump()
        XCTAssertEqual(text, "")
        XCTAssertTrue(canRedo)
    }
}
