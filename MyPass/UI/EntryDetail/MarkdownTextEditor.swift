import SwiftUI
import AppKit

enum MarkdownWrapAction {
    case wrap(prefix: String, suffix: String)
}

/// Undo/redo requests from outside the text view (the toolbar buttons). Keyboard
/// shortcuts need no command: Cmd-Z / Shift-Cmd-Z reach the focused NSTextView
/// through the responder chain on their own.
enum MarkdownEditorCommand {
    case undo, redo
    /// Replaces the whole text as ONE undoable step (restoring a draft).
    case replaceAll(String)
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var wrapAction: MarkdownWrapAction?
    @Binding var command: MarkdownEditorCommand?
    @Binding var canUndo: Bool
    @Binding var canRedo: Bool

    init(
        text: Binding<String>,
        wrapAction: Binding<MarkdownWrapAction?>,
        command: Binding<MarkdownEditorCommand?> = .constant(nil),
        canUndo: Binding<Bool> = .constant(false),
        canRedo: Binding<Bool> = .constant(false)
    ) {
        _text = text
        _wrapAction = wrapAction
        _command = command
        _canUndo = canUndo
        _canRedo = canRedo
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.canUndo = $canUndo
        context.coordinator.canRedo = $canRedo
        if textView.string != text {
            // An external replacement (another entry loaded into a reused editor)
            // is a new document: no undo registration, and the stack is cleared so
            // Undo can never carry one entry's text into another. Draft restores
            // use the undoable `.replaceAll` command instead.
            context.coordinator.setExternalText(text, in: textView)
        }
        if let action = wrapAction {
            context.coordinator.apply(action, to: textView)
            // Reset synchronously, before returning from this update pass. Deferring
            // this via DispatchQueue.main.async left a window where a SwiftUI-triggered
            // re-entrant updateNSView (from the `text` mutation inside apply()) could
            // observe a still-non-nil wrapAction and re-apply the same action a second
            // time against the already-wrapped selection. A synchronous reset closes
            // that race at the cost of a possible one-time "modifying state during
            // view update" console warning, which is an acceptable trade-off here.
            wrapAction = nil
        }
        // The `command` reset and the canUndo/canRedo writes below happen inside the
        // update pass, like the synchronous `wrapAction` reset above: deferring the
        // command reset would let a re-entrant update re-run it, and the flag writes
        // are guarded by inequality so they only fire on real changes. The cost is a
        // possible one-time "modifying state during view update" console warning.
        if let pending = command {
            context.coordinator.perform(pending, on: textView)
            command = nil
        }
        context.coordinator.refreshUndoState(of: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, canUndo: $canUndo, canRedo: $canRedo)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        weak var textView: NSTextView?

        /// The editor's own undo stack. NSTextView would otherwise use the window's
        /// manager, shared with the title field and others, so toolbar Undo could
        /// revert unrelated edits and canUndo would reflect the whole window.
        let undoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        var canUndo: Binding<Bool>
        var canRedo: Binding<Bool>

        init(
            text: Binding<String>,
            canUndo: Binding<Bool> = .constant(false),
            canRedo: Binding<Bool> = .constant(false)
        ) {
            self.text = text
            self.canUndo = canUndo
            self.canRedo = canRedo
        }

        func refreshUndoState(of textView: NSTextView) {
            let canUndoNow = undoManager.canUndo
            let canRedoNow = undoManager.canRedo
            if canUndo.wrappedValue != canUndoNow { canUndo.wrappedValue = canUndoNow }
            if canRedo.wrappedValue != canRedoNow { canRedo.wrappedValue = canRedoNow }
        }

        func perform(_ command: MarkdownEditorCommand, on textView: NSTextView) {
            switch command {
            case .undo: undoManager.undo()
            case .redo: undoManager.redo()
            case .replaceAll(let newText): replaceAll(in: textView, with: newText)
            }
            text.wrappedValue = textView.string
            refreshUndoState(of: textView)
        }

        /// Loads text that did not come from the user (another entry): not undoable,
        /// and the stack is reset because it is a new document.
        func setExternalText(_ newText: String, in textView: NSTextView) {
            textView.string = newText
            undoManager.removeAllActions()
            refreshUndoState(of: textView)
        }

        /// Replaces the whole content as a single undo step. Going through
        /// `shouldChangeText` + `replaceCharacters` registers the change with the
        /// undo manager; the explicit group and `breakUndoCoalescing` keep it from
        /// merging with neighbouring typing.
        func replaceAll(in textView: NSTextView, with newText: String) {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            let manager = undoManager
            textView.breakUndoCoalescing()
            manager.beginUndoGrouping()
            if textView.shouldChangeText(in: full, replacementString: newText) {
                textView.replaceCharacters(in: full, with: newText)
                textView.didChangeText()
            } else {
                // The delegate vetoed the change (or the view is not editable): the
                // content must still end up replaced, just not as an undo step.
                textView.string = newText
                text.wrappedValue = newText
            }
            manager.endUndoGrouping()
            textView.breakUndoCoalescing()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            refreshUndoState(of: textView)
        }

        func apply(_ action: MarkdownWrapAction, to textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            textView.breakUndoCoalescing()
            let nsString = textView.string as NSString
            let selectedText = nsString.substring(with: selectedRange)

            switch action {
            case .wrap(let prefix, let suffix):
                let replacement = "\(prefix)\(selectedText)\(suffix)"
                textView.insertText(replacement, replacementRange: selectedRange)
                let newCursorLocation = selectedRange.location + prefix.count + selectedText.count + suffix.count
                textView.setSelectedRange(NSRange(location: newCursorLocation, length: 0))
            }
            textView.breakUndoCoalescing()
            text.wrappedValue = textView.string
            refreshUndoState(of: textView)
        }
    }
}
