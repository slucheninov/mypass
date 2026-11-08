import SwiftUI
import AppKit

enum MarkdownWrapAction {
    case wrap(prefix: String, suffix: String)
}

/// Imperative handle for actions that originate outside the text view (the toolbar
/// buttons, draft restore). Keyboard shortcuts need none: Cmd-Z / Shift-Cmd-Z reach the
/// focused NSTextView through the responder chain on their own.
///
/// Why a handle and not state bindings: a one-shot command carried as a binding has to
/// be consumed (and reset) inside `updateNSView`. SwiftUI does not reliably honour state
/// writes made during an update pass, so the reset could be dropped while the side effect
/// (which writes `text`) invalidated the view again, and the next pass re-ran the same
/// command forever: Undo erased the text and wrapping inserted dozens of `**` before the
/// app hung. Calling through this handle from a button action or `onReceive` runs the
/// action from an event handler, outside any update pass, so nothing has to be reset.
///
/// The handle is a plain class: attaching the coordinator is a property assignment that
/// SwiftUI does not observe, so it is safe to do from `makeNSView` / `updateNSView`.
final class MarkdownEditorActions {
    fileprivate weak var coordinator: MarkdownTextEditor.Coordinator?

    init() {}

    func undo() { coordinator?.undo() }
    func redo() { coordinator?.redo() }
    func wrap(prefix: String, suffix: String) {
        coordinator?.apply(.wrap(prefix: prefix, suffix: suffix))
    }
    /// Replaces the whole text as ONE undoable step (restoring a draft).
    func replaceAll(_ newText: String) { coordinator?.replaceAll(with: newText) }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let actions: MarkdownEditorActions
    @Binding var canUndo: Bool
    @Binding var canRedo: Bool
    /// Notes entries keep the monospaced face; login notes use the proportional body font.
    var usesMonospacedFont: Bool
    /// When true Tab / Shift-Tab move keyboard focus to the next / previous field instead of
    /// inserting a tab (login notes, which have no markdown toolbar).
    var tabMovesFocus: Bool

    init(
        text: Binding<String>,
        actions: MarkdownEditorActions,
        canUndo: Binding<Bool> = .constant(false),
        canRedo: Binding<Bool> = .constant(false),
        usesMonospacedFont: Bool = true,
        tabMovesFocus: Bool = false
    ) {
        _text = text
        self.actions = actions
        _canUndo = canUndo
        _canRedo = canRedo
        self.usesMonospacedFont = usesMonospacedFont
        self.tabMovesFocus = tabMovesFocus
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = usesMonospacedFont
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        actions.coordinator = context.coordinator
        return scrollView
    }

    /// Must stay free of SwiftUI state writes (see `MarkdownEditorActions`): it only
    /// re-attaches the coordinator and bindings, and mirrors external text into the view.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.canUndo = $canUndo
        context.coordinator.canRedo = $canRedo
        actions.coordinator = context.coordinator
        if textView.string != text {
            // An external replacement (another entry loaded into a reused editor)
            // is a new document: no undo registration, and the stack is cleared so
            // Undo can never carry one entry's text into another. Draft restores
            // use the undoable `MarkdownEditorActions.replaceAll` instead.
            context.coordinator.setExternalText(text, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, canUndo: $canUndo, canRedo: $canRedo, tabMovesFocus: tabMovesFocus)
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
        let tabMovesFocus: Bool

        init(
            text: Binding<String>,
            canUndo: Binding<Bool> = .constant(false),
            canRedo: Binding<Bool> = .constant(false),
            tabMovesFocus: Bool = false
        ) {
            self.tabMovesFocus = tabMovesFocus
            self.text = text
            self.canUndo = canUndo
            self.canRedo = canRedo
            super.init()
            // Cmd-Z / Shift-Cmd-Z are handled by NSTextView itself, and an undo or redo
            // replays the stored change without telling the delegate (`textDidChange` never
            // fires). Without this, the `text` binding would stay stale, and the next
            // updateNSView would see `textView.string != text`, treat it as an external
            // document, restore the stale text and wipe the undo/redo stacks. The manager's
            // own notifications fire for every path (keyboard, menu, toolbar).
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(undoManagerDidChange(_:)), name: name, object: undoManager)
            }
        }

        @objc private func undoManagerDidChange(_ note: Notification) {
            syncAfterAction()
        }

        func refreshUndoState(of textView: NSTextView) {
            let canUndoNow = undoManager.canUndo
            let canRedoNow = undoManager.canRedo
            if canUndo.wrappedValue != canUndoNow { canUndo.wrappedValue = canUndoNow }
            if canRedo.wrappedValue != canRedoNow { canRedo.wrappedValue = canRedoNow }
        }

        func undo() {
            undoManager.undo()
            syncAfterAction()
        }

        func redo() {
            undoManager.redo()
            syncAfterAction()
        }

        private func syncAfterAction() {
            guard let textView else { return }
            if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
            refreshUndoState(of: textView)
        }

        /// Loads text that did not come from the user (another entry): not undoable,
        /// and the stack is reset because it is a new document.
        func setExternalText(_ newText: String, in textView: NSTextView) {
            textView.string = newText
            undoManager.removeAllActions()
            // This runs from updateNSView, where writing the flag bindings is a state
            // write during a view update (ignored or looping, see MarkdownEditorActions).
            // Defer to the next main-queue turn; the writes are inequality-guarded so
            // they are idempotent and cannot feed back into another update.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.refreshUndoState(of: textView)
            }
        }

        /// Replaces the whole content as a single undo step. Going through
        /// `shouldChangeText` + `replaceCharacters` registers the change with the
        /// undo manager; the explicit group and `breakUndoCoalescing` keep it from
        /// merging with neighbouring typing.
        func replaceAll(with newText: String) {
            guard let textView else { return }
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
            syncAfterAction()
        }

        /// Plain-text fields hand Tab / Shift-Tab to the key-view loop; NSTextView would
        /// otherwise insert a tab character and trap keyboard navigation inside the notes.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard tabMovesFocus else { return false }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            refreshUndoState(of: textView)
        }

        func apply(_ action: MarkdownWrapAction) {
            guard let textView else { return }
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
