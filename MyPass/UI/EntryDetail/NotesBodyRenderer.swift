import Foundation

/// Renders a Notes entry's markdown source for display in a plain SwiftUI `Text`.
///
/// Uses `.inlineOnlyPreservingWhitespace` rather than the default `.full` CommonMark
/// parsing: `.full` treats a single newline as a soft line break (rendered as a space),
/// collapsing multi-line notes onto one line, and only a blank line starts a new
/// paragraph. `.inlineOnlyPreservingWhitespace` preserves the source's line breaks and
/// whitespace exactly while still parsing inline spans (bold/italic/inline code) — it
/// also disables block-level parsing, which matches the already-documented limitation
/// that headers/HR/code-fences render as literal markdown characters, not visual blocks.
enum NotesBodyRenderer {
    static func render(_ notesBody: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: notesBody, options: options)) ?? AttributedString(notesBody)
    }
}
