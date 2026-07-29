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

    // Known limitation (accepted per spec): AttributedString(markdown:) renders
    // inline styles (bold/italic/inline code) but not block-level constructs —
    // headers/HR/code-fences remain visible as literal markdown characters.
    private var renderedBody: AttributedString {
        (try? AttributedString(markdown: entry.notesBody)) ?? AttributedString(entry.notesBody)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: entry.title.isEmpty ? "(untitled)" : entry.title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                DetailFieldsCard {
                    Text(renderedBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .contextMenu {
                    Button("Copy Note") { copy(entry.notesBody) }
                    Button("Show Large Type") { showLargeType = true }
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
        .toolbar {
            DetailActionsToolbarContent(onEdit: { navigationState.presentEdit(entryID: entry.uuid) })
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
