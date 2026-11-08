import XCTest
import AppKit
import SwiftUI
@testable import MyPass

@MainActor
final class MarkdownTextEditorUndoTests: XCTestCase {
    private final class Box { var text = ""; var canUndo = false; var canRedo = false }

    private var box: Box!
    private var window: NSWindow!
    private var textView: NSTextView!
    private var coordinator: MarkdownTextEditor.Coordinator!

    override func setUp() {
        super.setUp()
        box = Box()
        let b = box!
        coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { b.text }, set: { b.text = $0 }),
            canUndo: Binding(get: { b.canUndo }, set: { b.canUndo = $0 }),
            canRedo: Binding(get: { b.canRedo }, set: { b.canRedo = $0 })
        )
        // Hosted in a window so the window has its own (unrelated) undo manager;
        // the text view must use the coordinator's manager, not that one.
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.allowsUndo = true
        textView.isRichText = false
        textView.delegate = coordinator
        coordinator.textView = textView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        // No run loop turns in a unit test, so the automatic per-event grouping
        // would fold everything into one group; groups are opened explicitly.
        window.undoManager?.groupsByEvent = false
        coordinator.undoManager.groupsByEvent = false
    }

    override func tearDown() {
        window = nil; textView = nil; coordinator = nil
        super.tearDown()
    }

    private func type(_ s: String) {
        let um = coordinator.undoManager
        textView.breakUndoCoalescing()
        um.beginUndoGrouping()
        textView.insertText(s, replacementRange: textView.selectedRange())
        um.endUndoGrouping()
    }

    func testUndoRevertsLastTypedChangeAndUpdatesBinding() {
        type("hello")
        type(" world")
        XCTAssertEqual(box.text, "hello world")
        coordinator.undo()
        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(box.text, "hello")
    }

    func testRedoReappliesUndoneChange() {
        type("hello")
        coordinator.undo()
        XCTAssertEqual(box.text, "")
        coordinator.redo()
        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(box.text, "hello")
    }

    func testCanUndoCanRedoFlagsTrackUndoManager() {
        coordinator.refreshUndoState(of: textView)
        XCTAssertFalse(box.canUndo)
        XCTAssertFalse(box.canRedo)
        type("a")
        XCTAssertTrue(box.canUndo)
        XCTAssertFalse(box.canRedo)
        coordinator.undo()
        XCTAssertFalse(box.canUndo)
        XCTAssertTrue(box.canRedo)
    }

    func testApplyingMarkdownWrapIsUndoable() {
        type("word")
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let um = coordinator.undoManager
        um.beginUndoGrouping()
        coordinator.apply(.wrap(prefix: "**", suffix: "**"))
        um.endUndoGrouping()
        XCTAssertEqual(textView.string, "**word**")
        coordinator.undo()
        XCTAssertEqual(textView.string, "word")
        XCTAssertEqual(box.text, "word")
    }

    func testProgrammaticReplacementIsOneUndoStep() {
        type("original")
        coordinator.replaceAll(with: "restored from draft")
        XCTAssertEqual(textView.string, "restored from draft")
        XCTAssertEqual(box.text, "restored from draft")
        coordinator.undo()
        XCTAssertEqual(textView.string, "original")
        XCTAssertTrue(box.canUndo)
        coordinator.redo()
        XCTAssertEqual(textView.string, "restored from draft")
    }

    func testUndoDoesNotTouchWindowUndoManager() {
        let windowManager = window.undoManager!
        final class Target: NSObject { var fired = false }
        let target = Target()
        windowManager.beginUndoGrouping()
        windowManager.registerUndo(withTarget: target) { $0.fired = true }
        windowManager.endUndoGrouping()
        coordinator.refreshUndoState(of: textView)
        XCTAssertFalse(box.canUndo)
        type("abc")
        coordinator.undo()
        coordinator.undo()
        XCTAssertFalse(target.fired)
        XCTAssertTrue(windowManager.canUndo)
        XCTAssertEqual(textView.string, "")
    }

    func testExternalTextChangeResetsUndo() {
        type("abc")
        XCTAssertTrue(box.canUndo)
        coordinator.setExternalText("other entry", in: textView)
        XCTAssertEqual(textView.string, "other entry")
        // The flag refresh is deferred out of the update pass. The main queue is FIFO, so a
        // sentinel block enqueued now runs after it; no wall-clock wait needed.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(box.canUndo)
        XCTAssertFalse(box.canRedo)
    }
}
