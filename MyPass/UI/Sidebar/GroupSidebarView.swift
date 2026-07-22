import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                Text(group.name)
                    .tag(group.uuid)
                    .contextMenu {
                        Button("Новая подгруппа") {
                            vaultSession.mutate { _ in
                                GroupTreeOperations.addSubgroup(named: "Новая группа", to: group)
                            }
                        }
                        if group.uuid != rootGroup.uuid {
                            Button("Удалить группу", role: .destructive) {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.removeSubgroup(withID: group.uuid, from: database.rootGroup)
                                }
                            }
                        }
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        provider.loadObject(ofClass: NSString.self) { reading, _ in
                            guard let uuidString = reading as? String, let entryID = UUID(uuidString: uuidString) else { return }
                            DispatchQueue.main.async {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.moveEntry(withID: entryID, to: group.uuid, in: database.rootGroup)
                                }
                            }
                        }
                        return true
                    }
            }
            if let bin = rootGroup.subgroups.first(where: { $0.name == GroupTreeOperations.recycleBinGroupName }) {
                Text(GroupTreeOperations.recycleBinGroupName)
                    .tag(bin.uuid)
            } else {
                Text(GroupTreeOperations.recycleBinGroupName)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
