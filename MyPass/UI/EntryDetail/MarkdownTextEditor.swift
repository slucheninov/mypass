import SwiftUI
import AppKit

enum MarkdownWrapAction {
    case wrap(prefix: String, suffix: String)
    case linePrefix(String)
    case insertBlock(String)
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
            DispatchQueue.main.async { wrapAction = nil }
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
            case .linePrefix(let prefix):
                let lineRange = nsString.lineRange(for: selectedRange)
                let line = nsString.substring(with: lineRange)
                textView.insertText(prefix + line, replacementRange: lineRange)
            case .insertBlock(let block):
                textView.insertText(block, replacementRange: selectedRange)
            }
            text.wrappedValue = textView.string
        }
    }
}
