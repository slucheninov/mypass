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
                        countText: countText(for: category),
                        isSelected: navigationState.selectedSmartCategory == category
                    ) {
                        navigationState.selectSmartCategory(category)
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
                SidebarSectionHeader(title: "Groups") {
                    AnyView(
                        Button {
                            addSubgroupFromHeader()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("New Group")
                    )
                }
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
        .onChange(of: navigationState.selectedGroupID) { _, _ in
            navigationState.exitCategoryModeForGroupSelection()
        }
    }

    private func countText(for category: SmartCategory) -> String {
        guard let database = vaultSession.currentDatabase else { return "0" }
        return category.countDisplay(for: database)
    }

    private func addSubgroupFromHeader() {
        var newGroupID: UUID?
        vaultSession.mutate { database in
            let parent: KdbxGroup
            if let selectedID = navigationState.selectedGroupID,
               let selected = findGroup(uuid: selectedID, in: database.rootGroup),
               !GroupTreeOperations.isRecycleBinGroup(selected) {
                parent = selected
            } else {
                parent = database.rootGroup
            }
            let created = GroupTreeOperations.addSubgroup(named: "New Group", to: parent)
            newGroupID = created.uuid
        }
        if let newGroupID {
            navigationState.selectedGroupID = newGroupID
            navigationState.exitCategoryModeForGroupSelection()
        }
    }

    private func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == uuid { return group }
        for sub in group.subgroups {
            if let found = findGroup(uuid: uuid, in: sub) { return found }
        }
        return nil
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing() }
        }
    }
}

private struct SmartCategorySidebarRow: View {
    let category: SmartCategory
    let countText: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(category.accentColor)
                    .frame(width: 8, height: 8)
                Text(category.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(countText)
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
