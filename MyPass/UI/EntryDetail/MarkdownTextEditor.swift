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
            // Restore from a draft or an external change: register it as ONE
            // undoable step instead of assigning `string`, which would silently
            // drop the undo stack.
            context.coordinator.replaceAll(in: textView, with: text)
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
            // Always go through `textView.undoManager` so the window's manager is
            // used in production.
            let canUndoNow = textView.undoManager?.canUndo ?? false
            let canRedoNow = textView.undoManager?.canRedo ?? false
            if canUndo.wrappedValue != canUndoNow { canUndo.wrappedValue = canUndoNow }
            if canRedo.wrappedValue != canRedoNow { canRedo.wrappedValue = canRedoNow }
        }

        func perform(_ command: MarkdownEditorCommand, on textView: NSTextView) {
            switch command {
            case .undo: textView.undoManager?.undo()
            case .redo: textView.undoManager?.redo()
            }
            text.wrappedValue = textView.string
            refreshUndoState(of: textView)
        }

        /// Replaces the whole content as a single undo step. Going through
        /// `shouldChangeText` + `replaceCharacters` registers the change with the
        /// undo manager; the explicit group and `breakUndoCoalescing` keep it from
        /// merging with neighbouring typing.
        func replaceAll(in textView: NSTextView, with newText: String) {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            let manager = textView.undoManager
            textView.breakUndoCoalescing()
            manager?.beginUndoGrouping()
            if textView.shouldChangeText(in: full, replacementString: newText) {
                textView.replaceCharacters(in: full, with: newText)
                textView.didChangeText()
            }
            manager?.endUndoGrouping()
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
