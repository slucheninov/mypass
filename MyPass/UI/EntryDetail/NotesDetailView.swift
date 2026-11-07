import SwiftUI
import AppKit
import MyPassKit

struct NotesDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var showLargeType = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    // Known limitation (accepted per spec): renders inline styles (bold/italic/inline
    // code) but not block-level constructs — headers/HR/code-fences remain visible as
    // literal markdown characters. See NotesBodyRenderer for why this uses
    // .inlineOnlyPreservingWhitespace rather than default markdown parsing.
    private var renderedBody: AttributedString {
        NotesBodyRenderer.render(entry.notesBody)
    }

    private var isBlurred: Bool {
        NotesProtection.isBlurred(notes: entry.notesBody, state: navigationState.notesReveal, entryID: entry.uuid)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: entry.displayTitle,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(verbatim: entry.displayTitle)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                DetailFieldsCard {
                    ProtectedNotesBlock(entryID: entry.uuid, notes: entry.notesBody) {
                        Text(renderedBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .contextMenu {
                    // Disabled (not hidden) while blurred so the menu does not change
                    // shape on reveal and neither action can leak the real text.
                    Button("Copy Note") { copy(entry.notesBody) }
                        .disabled(isBlurred)
                    Button("Show Large Type") { showLargeType = true }
                        .disabled(isBlurred)
                }
                .popover(isPresented: $showLargeType) {
                    LargeTypePopover(text: entry.notesBody, isMonospaced: false)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Note")
        .onChange(of: isBlurred) { _, blurred in
            // Re-hide (minimize, lock) must also take down an open large-type popover.
            if blurred { showLargeType = false }
        }
        .onChange(of: navigationState.selectedEntryID) { _, newID in
            showLargeType = false
            if let newID {
                vaultSession.touchAccess(entryID: newID)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
        if let id = navigationState.selectedEntryID {
            vaultSession.touchAccess(entryID: id)
        }
    }
}
