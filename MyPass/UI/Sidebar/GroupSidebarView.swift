import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                Text(group.name)
                    .tag(group.uuid)
                    .contextMenu {
                        Button("New Subgroup") {
                            vaultSession.mutate { _ in
                                GroupTreeOperations.addSubgroup(named: "New Group", to: group)
                            }
                        }
                        if group.uuid != rootGroup.uuid {
                            Button("Delete Group", role: .destructive) {
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
            if let uuid = recycleBinGroupUUID, let bin = rootGroup.subgroups.first(where: { $0.uuid == uuid }) {
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
