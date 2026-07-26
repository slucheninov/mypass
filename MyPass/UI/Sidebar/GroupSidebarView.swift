import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            Section {
                ForEach(SmartCategory.allCases) { category in
                    SmartCategorySidebarRow(
                        category: category,
                        isSelected: navigationState.selectedSmartCategory == category
                    )
                    .onTapGesture {
                        // Wave 1: visual selection only — entry list filtering is unchanged.
                        navigationState.selectedSmartCategory = category
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Categories")
            }

            Section {
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
            } header: {
                SidebarSectionHeader(title: "Groups")
            }

            Section {
                if let uuid = recycleBinGroupUUID, let bin = rootGroup.subgroups.first(where: { $0.uuid == uuid }) {
                    Text(GroupTreeOperations.recycleBinGroupName)
                        .tag(bin.uuid)
                } else {
                    Text(GroupTreeOperations.recycleBinGroupName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: UIShellMetrics.sidebarPreferredWidth)
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SmartCategorySidebarRow: View {
    let category: SmartCategory
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(category.accentColor)
                .frame(width: 8, height: 8)
            Text(category.title)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(category.placeholderCount)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? category.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
