import SwiftUI
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @State private var isCreatingEntry = false
    @EnvironmentObject var vaultSession: VaultSession

    private var currentGroup: KdbxGroup {
        find(uuid: navigationState.selectedGroupID, in: rootGroup) ?? rootGroup
    }

    private var displayedEntries: [KdbxEntry] {
        navigationState.searchText.isEmpty
            ? currentGroup.entries
            : EntrySearch.entries(in: rootGroup, matching: navigationState.searchText)
    }

    var body: some View {
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? "(без названия)" : entry.title)
                Text(entry.login)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(entry.uuid)
            .draggable(entry.uuid.uuidString) // full drag-and-drop wiring completed in Task 15
        }
        .searchable(text: $navigationState.searchText)
        .toolbar {
            ToolbarItem {
                Button("Добавить", systemImage: "plus") {
                    isCreatingEntry = true
                }
            }
        }
        .sheet(isPresented: $isCreatingEntry) {
            EntryEditView(existingEntry: nil) { newEntry in
                vaultSession.mutate { database in
                    addEntry(newEntry, toGroupWithID: currentGroup.uuid, in: database.rootGroup)
                }
            }
        }
    }

    private func find(uuid: UUID?, in group: KdbxGroup) -> KdbxGroup? {
        guard let uuid else { return nil }
        if group.uuid == uuid { return group }
        for subgroup in group.subgroups {
            if let found = find(uuid: uuid, in: subgroup) { return found }
        }
        return nil
    }

    private func addEntry(_ entry: KdbxEntry, toGroupWithID groupID: UUID, in group: KdbxGroup) {
        if group.uuid == groupID {
            group.entries.append(entry)
            return
        }
        for subgroup in group.subgroups {
            addEntry(entry, toGroupWithID: groupID, in: subgroup)
        }
    }
}
