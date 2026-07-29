import SwiftUI
import AppKit

enum MarkdownWrapAction {
    case wrap(prefix: String, suffix: String)
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var wrapAction: MarkdownWrapAction?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
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
        if textView.string != text {
            textView.string = text
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func apply(_ action: MarkdownWrapAction, to textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let selectedText = nsString.substring(with: selectedRange)

            switch action {
            case .wrap(let prefix, let suffix):
                let replacement = "\(prefix)\(selectedText)\(suffix)"
                textView.insertText(replacement, replacementRange: selectedRange)
                let newCursorLocation = selectedRange.location + prefix.count + selectedText.count + suffix.count
                textView.setSelectedRange(NSRange(location: newCursorLocation, length: 0))
            }
            text.wrappedValue = textView.string
        }
    }
}
