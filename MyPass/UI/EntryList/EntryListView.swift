import SwiftUI
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState

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
                    // wired to EntryEditView in Task 14
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
}
