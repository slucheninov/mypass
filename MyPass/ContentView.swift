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
                EntryDetailView()
            }
            .alert(
                "Ошибка сохранения",
                isPresented: Binding(
                    get: { vaultSession.lastSaveError != nil },
                    set: { if !$0 { vaultSession.acknowledgeSaveError() } }
                ),
                actions: {},
                message: { Text(vaultSession.lastSaveError ?? "") }
            )
            .sheet(item: $navigationState.pendingSaveProposal) { proposal in
                EntryEditView(existingEntry: draftEntry(from: proposal)) { entry in
                    vaultSession.mutate { database in
                        database.rootGroup.entries.append(entry)
                    }
                    navigationState.pendingSaveProposal = nil
                }
            }
        }
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
