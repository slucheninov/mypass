import SwiftUI
import MyPassKit

struct ContentView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState

    private var isVaultLocked: Bool { vaultSession.currentDatabase == nil }

    var body: some View {
        // These two observers must sit OUTSIDE the switch. Anything attached inside the
        // `.unlocked` branch is torn down when the vault locks, so a handler that resets
        // state would simply never run — which previously left the window stuck at
        // `.floating` above every other app until the app restarted.
        vaultContent
            .onChange(of: navigationState.pendingPairingCode) { _, code in
                MainWindowActivator.setMainWindowFloating(code != nil)
            }
            .onChange(of: isVaultLocked) { _, locked in
                guard locked else { return }
                // A pairing challenge must not outlive the vault it authorises: pairing
                // itself is gated on an unlocked vault, so a code left on screen after a
                // lock is both useless and misleading.
                if navigationState.pendingPairingCode != nil {
                    AppDelegate.extensionPairingManager?.cancelPairing()
                    navigationState.pendingPairingCode = nil
                }
                MainWindowActivator.setMainWindowFloating(false)
            }
    }

    @ViewBuilder
    private var vaultContent: some View {
        switch vaultSession.state {
        case .locked:
            UnlockView()
        case .unlocked(let database):
            NavigationSplitView {
                GroupSidebarView(rootGroup: database.rootGroup, recycleBinGroupUUID: database.recycleBinGroupUUID)
            } content: {
                EntryListView(rootGroup: database.rootGroup)
            } detail: {
                DetailColumnView(rootGroup: database.rootGroup)
            }
            .alert(
                "Save Error",
                isPresented: Binding(
                    get: { vaultSession.lastSaveError != nil },
                    set: { if !$0 { vaultSession.acknowledgeSaveError() } }
                ),
                actions: {},
                message: { Text(vaultSession.lastSaveError ?? "") }
            )
            .onAppear {
                // Covers both the closed-window case (proposal set before ContentView —
                // and therefore these onChange handlers — existed, so .onChange never saw
                // the initial value) and the locked-vault case (proposal set while this
                // branch was torn down; consumed once it reappears after unlock).
                navigationState.consumePendingProposals()
            }
            .onChange(of: navigationState.pendingSaveProposal) { _, proposal in
                guard proposal != nil else { return }
                navigationState.consumePendingProposals()
            }
            .onChange(of: navigationState.pendingTotpSaveProposal) { _, proposal in
                guard proposal != nil else { return }
                navigationState.consumePendingProposals()
            }
            .onChange(of: navigationState.selectedEntryID) { oldID, newID in
                guard navigationState.detailPresentation != .browse else { return }
                if newID != oldID {
                    navigationState.presentBrowse()
                }
            }
            .sheet(isPresented: Binding(
                get: { navigationState.pendingPairingCode != nil },
                set: { if !$0 { navigationState.pendingPairingCode = nil } }
            )) {
                if let code = navigationState.pendingPairingCode {
                    PairingCodeSheet(code: code) {
                        AppDelegate.extensionPairingManager?.cancelPairing()
                    }
                }
            }
        }
    }
}

private struct DetailColumnView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        switch navigationState.detailPresentation {
        case .browse:
            browseDetail()
        case .edit(let entryID):
            entryEdit(existingID: entryID)
        case .create(let defaultGroupID, let entryType):
            entryEdit(existingID: nil, defaultGroupID: defaultGroupID, entryType: entryType)
        case .createFromProposal(let proposal):
            entryEdit(existingID: nil, proposal: proposal)
        case .createFromTotpProposal(let proposal):
            entryEdit(existingID: nil, totpProposal: proposal)
        case .editFromTotpProposal(let entryID, let otpauthInput):
            entryEdit(existingID: entryID, prefilledOtpauthInput: otpauthInput)
        }
    }

    private var currentBrowseEntry: KdbxEntry? {
        guard let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: rootGroup).first { $0.uuid == id }
    }

    @ViewBuilder
    private func browseDetail() -> some View {
        if let entry = currentBrowseEntry {
            switch entry.entryType {
            case .address:
                AddressDetailView(entry: entry)
            case .card:
                CardDetailView(entry: entry)
            case .notes:
                NotesDetailView(entry: entry)
            case .login:
                EntryDetailView()
            }
        } else {
            scopeOverview
        }
    }

    private var scopeOverview: some View {
        let category = navigationState.selectedSmartCategory
        let group = EntryListQuery.currentGroup(in: rootGroup, selectedID: navigationState.selectedGroupID)
        let categoryMode = navigationState.isCategoryMode
        let count = EntryListQuery.entries(root: rootGroup, database: vaultSession.currentDatabase, navigation: navigationState).count
        return ScopeOverviewView(
            title: categoryMode ? category.title : group.name,
            symbolName: categoryMode ? category.symbolName : "folder",
            emoji: categoryMode ? nil : group.emoji,
            accentColor: categoryMode ? category.accentColor : .secondary,
            itemCount: count,
            isSearching: !navigationState.searchText.isEmpty,
            searchesWholeVault: !categoryMode || (category == .security && navigationState.securityUsesGroupScope)
        )
    }

    @ViewBuilder
    private func entryEdit(
        existingID: UUID?,
        defaultGroupID: UUID? = nil,
        proposal: PendingSaveProposal? = nil,
        totpProposal: PendingTotpSaveProposal? = nil,
        prefilledOtpauthInput: String? = nil,
        entryType: EntryType = .login
    ) -> some View {
        let targetGroupID = resolvedDefaultGroupID(existingID: existingID, defaultGroupID: defaultGroupID)
        let existingEntry = resolvedEntry(existingID: existingID, proposal: proposal, totpProposal: totpProposal)
        let resolvedType = existingEntry?.entryType ?? entryType
        let recycleBinGroupUUID = vaultSession.currentDatabase?.recycleBinGroupUUID

        let onCancel: () -> Void = { navigationState.presentBrowse() }
        let onSave: (KdbxEntry, UUID) -> Void = { saved, selectedGroupID in
            vaultSession.mutate { database in
                if let existingID {
                    EntryPersistence.replaceEntry(saved, in: database.rootGroup)
                    if let location = GroupTreeOperations.entryLocation(entryID: existingID, in: database.rootGroup),
                       location.group.uuid != selectedGroupID {
                        GroupTreeOperations.moveEntry(withID: saved.uuid, to: selectedGroupID, in: database.rootGroup)
                    }
                } else {
                    EntryPersistence.addEntry(saved, toGroupWithID: selectedGroupID, in: database.rootGroup)
                }
            }
            navigationState.selectedEntryID = saved.uuid
            navigationState.presentBrowse()
        }
        let onDelete: () -> Void = {
            guard let existingEntry else { return }
            vaultSession.mutate { database in
                GroupTreeOperations.softDeleteEntry(
                    withID: existingEntry.uuid,
                    in: database.rootGroup,
                    deletedObjects: &database.deletedObjects,
                    recycleBinGroupUUID: &database.recycleBinGroupUUID
                )
            }
            navigationState.selectedEntryID = nil
            navigationState.presentBrowse()
        }

        switch resolvedType {
        case .login:
            EntryEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete,
                // The create path carries the OTP inside the proposal itself;
                // the edit path passes it explicitly via prefilledOtpauthInput.
                prefilledOtpauthInput: prefilledOtpauthInput ?? totpProposal?.otpauthOrSecret
            )
            .id(navigationState.detailPresentation)
        case .address:
            AddressEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        case .card:
            CardEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        case .notes:
            NotesEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        }
    }

    private func resolvedDefaultGroupID(existingID: UUID?, defaultGroupID: UUID?) -> UUID {
        let binUUID = vaultSession.currentDatabase?.recycleBinGroupUUID
        let raw: UUID
        if let defaultGroupID {
            raw = defaultGroupID
        } else if let existingID,
                  let location = GroupTreeOperations.entryLocation(entryID: existingID, in: rootGroup) {
            raw = location.group.uuid
        } else {
            raw = navigationState.selectedGroupID ?? rootGroup.uuid
        }
        return GroupTreeOperations.clampedDefaultGroupID(raw, in: rootGroup, recycleBinGroupUUID: binUUID)
    }

    private func resolvedEntry(existingID: UUID?, proposal: PendingSaveProposal?, totpProposal: PendingTotpSaveProposal? = nil) -> KdbxEntry? {
        if let proposal {
            return draftEntry(from: proposal)
        }
        if let totpProposal {
            return draftEntry(from: totpProposal)
        }
        guard let existingID, let database = vaultSession.currentDatabase else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == existingID }
    }

    private func draftEntry(from proposal: PendingSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = proposal.registrableDomain
        entry.login = proposal.username
        entry.password = proposal.password
        entry.url = proposal.url
        return entry
    }

    private func draftEntry(from totpProposal: PendingTotpSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = totpProposal.registrableDomain
        entry.url = totpProposal.url
        return entry
    }
}

enum EntryPersistence {
    static func replaceEntry(_ updated: KdbxEntry, in group: KdbxGroup) {
        if let index = group.entries.firstIndex(where: { $0.uuid == updated.uuid }) {
            group.entries[index] = updated
            return
        }
        for subgroup in group.subgroups {
            replaceEntry(updated, in: subgroup)
        }
    }

    static func addEntry(_ entry: KdbxEntry, toGroupWithID groupID: UUID, in group: KdbxGroup) {
        if group.uuid == groupID {
            group.entries.append(entry)
            return
        }
        for subgroup in group.subgroups {
            addEntry(entry, toGroupWithID: groupID, in: subgroup)
        }
    }
}
