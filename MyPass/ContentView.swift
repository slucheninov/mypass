import SwiftUI
import MyPassKit

struct ContentView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
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
            .onChange(of: navigationState.pendingSaveProposal) { _, proposal in
                if let proposal {
                    navigationState.presentCreateFromProposal(proposal)
                    navigationState.pendingSaveProposal = nil
                }
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
            EntryDetailView()
        case .edit(let entryID):
            entryEdit(existingID: entryID)
        case .create(let defaultGroupID):
            entryEdit(existingID: nil, defaultGroupID: defaultGroupID)
        case .createFromProposal(let proposal):
            entryEdit(existingID: nil, proposal: proposal)
        }
    }

    @ViewBuilder
    private func entryEdit(
        existingID: UUID?,
        defaultGroupID: UUID? = nil,
        proposal: PendingSaveProposal? = nil
    ) -> some View {
        let targetGroupID = resolvedDefaultGroupID(existingID: existingID, defaultGroupID: defaultGroupID)
        EntryEditView(
            existingEntry: resolvedEntry(existingID: existingID, proposal: proposal),
            rootGroup: rootGroup,
            recycleBinGroupUUID: vaultSession.currentDatabase?.recycleBinGroupUUID,
            defaultGroupID: targetGroupID,
            onCancel: { navigationState.presentBrowse() },
            onSave: { saved, selectedGroupID in
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
        )
        .id(navigationState.detailPresentation)
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

    private func resolvedEntry(existingID: UUID?, proposal: PendingSaveProposal?) -> KdbxEntry? {
        if let proposal {
            return draftEntry(from: proposal)
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
