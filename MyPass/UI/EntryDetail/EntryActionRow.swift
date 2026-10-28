import SwiftUI
import MyPassKit

/// Shared chrome of the two in-column action rows: a 44pt bar with the detail column's
/// own background and a bottom hairline.
///
/// These rows replace what used to be window-toolbar items (Edit; Cancel / Save / star).
/// The window toolbar is now a stable "+" / search / Import group that must not change
/// with the selection, so everything that belongs to the *selected entry* lives at the top
/// of the detail column instead. They are attached with `.safeAreaInset(edge: .top)` so
/// the scrolling content starts below the bar rather than underneath it.
private struct EntryActionRowChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 24)
            .frame(height: 44)
            Divider()
        }
        .background(UIShellMetrics.detailColumnBackground)
    }
}

/// Browse-mode row: right-aligned Edit button plus the ⋮ entry actions menu.
struct EntryBrowseActionRow: View {
    let entry: KdbxEntry

    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState
    @State private var showHistory = false
    // Separate from the `showDeletePermanentlyAlert` in `EntryDetailView` (which backs
    // that view's inline Recycle Bin button): each alert is driven by its own state, set
    // only by its own button, so the two can never be presented at the same time.
    @State private var showDeletePermanentlyAlert = false

    private var isInRecycleBin: Bool {
        guard let database = vaultSession.currentDatabase else { return false }
        return RecycleBinEntryFilter.isInRecycleBin(entry, database: database)
    }

    var body: some View {
        EntryActionRowChrome {
            Spacer(minLength: 0)
            Button("Edit", systemImage: "pencil") {
                navigationState.presentEdit(entryID: entry.uuid)
            }
            Menu {
                menuContent
            } label: {
                // `ellipsis` rotated 90 degrees reads as the vertical "more" glyph; the
                // frame keeps its hit target the same height as the Edit button.
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(
                entry: entry,
                onRestore: { updated in
                    vaultSession.mutate { database in
                        EntryPersistence.replaceEntry(updated, in: database.rootGroup)
                    }
                    showHistory = false
                },
                onClearHistory: { updated in
                    vaultSession.mutate { database in
                        EntryPersistence.replaceEntry(updated, in: database.rootGroup)
                    }
                    showHistory = false
                }
            )
        }
        .alert("Delete Permanently?", isPresented: $showDeletePermanentlyAlert) {
            Button("Delete Permanently", role: .destructive) {
                EntryActions.deletePermanently(entryID: entry.uuid, in: vaultSession)
                navigationState.selectedEntryID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This entry will be permanently deleted. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        let model = EntryActionMenuModel(entry: entry, isInRecycleBin: isInRecycleBin)
        ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(Array(section.enumerated()), id: \.offset) { _, item in
                menuItem(item)
            }
        }
    }

    @ViewBuilder
    private func menuItem(_ item: EntryActionMenuModel.Item) -> some View {
        switch item {
        case .toggleFavorite(let isFavorite):
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                EntryActions.toggleFavorite(entryID: entry.uuid, in: vaultSession)
            }
        case .moveToGroup:
            moveToGroupMenu
        case .copy(let kind, let isEnabled):
            Button(copyTitle(kind)) {
                // `nil` (a one-time code that could not be generated) copies nothing:
                // writing "" would wipe whatever the user has on the clipboard.
                guard let value = copyValue(kind) else { return }
                EntryActions.copy(value, entryID: entry.uuid, in: vaultSession)
            }
            .disabled(!isEnabled)
        case .openWebsite:
            Button("Open Website") {
                guard let website = entry.primaryWebsiteURL else { return }
                EntryActions.openWebsite(website)
            }
        case .viewHistory:
            Button("View History") { showHistory = true }
        case .delete:
            // No confirmation: the entry lands in the Recycle Bin and stays recoverable.
            Button("Delete") {
                EntryActions.moveToRecycleBin(entryID: entry.uuid, in: vaultSession)
                navigationState.selectedEntryID = nil
            }
        case .restore:
            Button("Restore") {
                EntryActions.restore(entryID: entry.uuid, in: vaultSession)
                navigationState.selectedEntryID = nil
            }
        case .deletePermanently:
            Button("Delete Permanently…", role: .destructive) {
                showDeletePermanentlyAlert = true
            }
        }
    }

    @ViewBuilder
    private var moveToGroupMenu: some View {
        if let database = vaultSession.currentDatabase {
            let groups = GroupTreeOperations.selectableGroups(in: database.rootGroup, excludingRecycleBin: database.recycleBinGroupUUID)
            let currentGroupID = GroupTreeOperations.entryLocation(entryID: entry.uuid, in: database.rootGroup)?.group.uuid
            Menu("Move to Group") {
                ForEach(groups, id: \.uuid) { group in
                    Button {
                        EntryActions.move(entryID: entry.uuid, toGroup: group.uuid, in: vaultSession)
                    } label: {
                        // Group names are vault data: shown verbatim, never localized (only the
                        // Recycle Bin, which is not selectable here anyway, has a localized label).
                        HStack {
                            Text(verbatim: GroupTreeOperations.displayName(for: group, recycleBinGroupUUID: database.recycleBinGroupUUID))
                            if group.uuid == currentGroupID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    private func copyTitle(_ kind: EntryActionMenuModel.CopyKind) -> LocalizedStringKey {
        switch kind {
        case .username: "Copy Username"
        case .password: "Copy Password"
        case .code: "Copy Code"
        case .cardNumber: "Copy Card Number"
        case .cvv: "Copy CVV"
        case .note: "Copy Note"
        }
    }

    private func copyValue(_ kind: EntryActionMenuModel.CopyKind) -> String? {
        switch kind {
        case .username: entry.login
        case .password: entry.password
        case .code:
            // The *current* one-time code, computed at click time with the same
            // generator and parameters the detail view's verification-code row uses
            // (6 digits, 30 s, SHA-1) -- never the shared secret itself.
            entry.totpSecretBase32.flatMap {
                TOTPCode.currentCode(secretBase32: $0, digits: 6, period: 30, algorithm: .sha1, now: Date())
            }
        case .cardNumber: entry.cardNumber
        case .cvv: entry.cvv
        case .note: entry.notesBody
        }
    }
}

/// Edit-mode row: star toggle on the left, Cancel and Save on the right.
///
/// The favorite star used to be a window-toolbar item; it lives here so the window
/// toolbar stays independent of the detail column's mode.
struct EntryEditActionRow: View {
    @Binding var isFavorite: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        EntryActionRowChrome {
            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
            }
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
            Button("Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
