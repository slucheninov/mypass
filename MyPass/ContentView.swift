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
        }
    }
}
