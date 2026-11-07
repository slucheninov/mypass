import SwiftUI

/// Wraps an entry's notes so they stay hidden until the user deliberately reveals them.
///
/// While blurred the real text is NOT in the view tree at all: `content` is never
/// evaluated, so there is nothing for text selection, copy, drag, Accessibility or a
/// screen capture of the view hierarchy to expose. A CSS-style blur over the real text
/// would still leave it selectable and readable by VoiceOver, so the blur is applied to
/// a fixed, constant placeholder instead. Purpose: protection against accidental reveal
/// and screen sharing, not against a determined local attacker.
struct ProtectedNotesBlock<Content: View>: View {
    let entryID: UUID
    let notes: String
    @ViewBuilder let content: () -> Content

    @EnvironmentObject private var navigationState: NavigationState

    private var isBlurred: Bool {
        NotesProtection.isBlurred(notes: notes, state: navigationState.notesReveal, entryID: entryID)
    }

    // Constant widths: the placeholder must not leak the length or shape of the real text.
    private static var placeholderLineWidths: [CGFloat] { [1.0, 0.85, 0.95, 0.6] }

    var body: some View {
        if isBlurred {
            Button {
                navigationState.notesReveal.reveal(entryID: entryID)
            } label: {
                ZStack {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Self.placeholderLineWidths.enumerated()), id: \.offset) { _, fraction in
                            GeometryReader { proxy in
                                Text(verbatim: String(repeating: "\u{2022}", count: 40))
                                    .lineLimit(1)
                                    .frame(width: proxy.size.width * fraction, alignment: .leading)
                                    .clipped()
                            }
                            .frame(height: 18)
                        }
                    }
                    .blur(radius: 6)
                    .accessibilityHidden(true)

                    Text("Click to show")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Notes hidden")
            .accessibilityHint("Click to show")
        } else {
            content()
        }
    }
}
