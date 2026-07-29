import Foundation
import SwiftUI

/// Renders a Notes entry's markdown source for display in a plain SwiftUI `Text`.
///
/// Uses `.inlineOnlyPreservingWhitespace` rather than the default `.full` CommonMark
/// parsing: `.full` treats a single newline as a soft line break (rendered as a space),
/// collapsing multi-line notes onto one line, and only a blank line starts a new
/// paragraph. `.inlineOnlyPreservingWhitespace` preserves the source's line breaks and
/// whitespace exactly while still parsing inline spans (bold/italic/inline code).
///
/// `Text` doesn't automatically apply a distinct style to code spans, so inline code
/// runs get a monospaced font applied here manually. Block-level markdown (headers, HR,
/// fenced code blocks) is intentionally not supported — the Notes toolbar only offers
/// formatting this renderer can actually display.
enum NotesBodyRenderer {
    static func render(_ notesBody: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: notesBody, options: options)) ?? AttributedString(notesBody)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
        }
        return attributed
    }
}
