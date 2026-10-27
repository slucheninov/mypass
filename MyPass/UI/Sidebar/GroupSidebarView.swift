import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    @State private var showingCreateSheet = false
    @State private var groupBeingEdited: KdbxGroup?
    @State private var groupPendingDeletion: KdbxGroup?
    @State private var showEmptyRecycleBinAlert = false

    var body: some View {
        List(selection: $navigationState.sidebarSelectedGroupID) {
            Section {
                ForEach(SmartCategory.allCases) { category in
                    SmartCategorySidebarRow(
                        category: category,
                        countText: countText(for: category),
                        isSelected: navigationState.isSmartCategorySelected(category)
                    ) {
                        navigationState.selectSmartCategory(category)
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Categories")
            }

            Section {
                groupRow(rootGroup)

                ForEach(flattenedGroups, id: \.uuid) { group in
                    groupRow(group)
                        .contextMenu {
                            Button("Edit Group…") {
                                groupBeingEdited = group
                            }
                            Button("Delete Group…", role: .destructive) {
                                groupPendingDeletion = group
                            }
                        }
                }
            } header: {
                SidebarSectionHeader(title: "Groups") {
                    AnyView(
                        Button {
                            showingCreateSheet = true
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
                    Text(verbatim: GroupTreeOperations.recycleBinDisplayName)
                        .tag(bin.uuid)
                        .contextMenu {
                            Button("Empty Recycle Bin…", role: .destructive) {
                                showEmptyRecycleBinAlert = true
                            }
                            .disabled(EntrySearch.allEntries(in: bin).isEmpty)
                        }
                } else {
                    Text(verbatim: GroupTreeOperations.recycleBinDisplayName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: UIShellMetrics.sidebarPreferredWidth)
        .onChange(of: navigationState.selectedGroupID) { _, _ in
            navigationState.exitCategoryModeForGroupSelection()
        }
        .sheet(isPresented: $showingCreateSheet) {
            GroupEditorSheet(mode: .create, name: "", emoji: nil) { name, emoji in
                createGroup(named: name, emoji: emoji)
            }
        }
        .sheet(item: $groupBeingEdited) { group in
            GroupEditorSheet(mode: .edit, name: group.name, emoji: group.emoji) { name, emoji in
                vaultSession.mutate { database in
                    GroupTreeOperations.updateGroup(withID: group.uuid, name: name, emoji: emoji, in: database.rootGroup)
                }
            }
        }
        .alert(item: $groupPendingDeletion) { group in
            Alert(
                title: Text("Delete \"\(group.name)\"?"),
                message: Text("Entries in this group will be moved to the Recycle Bin."),
                primaryButton: .destructive(Text("Delete")) {
                    confirmDeleteGroup(group)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Empty Recycle Bin?", isPresented: $showEmptyRecycleBinAlert) {
            Button("Delete All", role: .destructive) {
                emptyRecycleBin()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently delete all \(recycleBinEntryCount) items in the Recycle Bin? This cannot be undone.")
        }
    }

    private var recycleBinEntryCount: Int {
        guard let uuid = recycleBinGroupUUID, let bin = rootGroup.subgroups.first(where: { $0.uuid == uuid }) else { return 0 }
        return EntrySearch.allEntries(in: bin).count
    }

    private func emptyRecycleBin() {
        vaultSession.mutate { database in
            GroupTreeOperations.emptyRecycleBin(
                in: database.rootGroup,
                deletedObjects: &database.deletedObjects,
                recycleBinGroupUUID: database.recycleBinGroupUUID
            )
        }
    }

    private var flattenedGroups: [KdbxGroup] {
        flattenSubgroups(rootGroup).filter { group in
            if group.uuid == rootGroup.uuid { return false }
            if PasswordGeneratorHistoryStore.isHistoryGroup(group) { return false }
            return !GroupTreeOperations.isTheRecycleBin(group, recycleBinGroupUUID: recycleBinGroupUUID)
        }
    }

    private func flattenSubgroups(_ group: KdbxGroup) -> [KdbxGroup] {
        group.subgroups.flatMap { subgroup in
            [subgroup] + flattenSubgroups(subgroup)
        }
    }

    @ViewBuilder
    private func groupRow(_ group: KdbxGroup) -> some View {
        HStack(spacing: 8) {
            if let emoji = group.emoji {
                Text(verbatim: emoji)
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: GroupTreeOperations.displayName(for: group, recycleBinGroupUUID: recycleBinGroupUUID))
            Spacer(minLength: 0)
            Text("\(group.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(group.uuid)
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

    private func createGroup(named name: String, emoji: String?) {
        var newGroupID: UUID?
        vaultSession.mutate { database in
            let created = GroupTreeOperations.addGroup(named: name, emoji: emoji, to: database.rootGroup)
            newGroupID = created.uuid
        }
        if let newGroupID {
            navigationState.selectedGroupID = newGroupID
            navigationState.exitCategoryModeForGroupSelection()
        }
    }

    private func confirmDeleteGroup(_ group: KdbxGroup) {
        let deletedIDs = GroupTreeOperations.subtreeGroupIDs(of: group)
        vaultSession.mutate { database in
            GroupTreeOperations.deleteGroup(
                withID: group.uuid,
                in: database.rootGroup,
                deletedObjects: &database.deletedObjects,
                recycleBinGroupUUID: &database.recycleBinGroupUUID
            )
        }
        if let selected = navigationState.selectedGroupID, deletedIDs.contains(selected) {
            navigationState.selectedGroupID = rootGroup.uuid
        }
    }

    private func countText(for category: SmartCategory) -> String {
        guard let database = vaultSession.currentDatabase else { return "0" }
        return category.countDisplay(for: database)
    }
}

private struct SidebarSectionHeader: View {
    let title: LocalizedStringKey
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        HStack {
            // `textCase` (not `String.uppercased()`) so the key is looked up first and the
            // translation is then upper-cased with the user's language rules.
            Text(title)
                .textCase(.uppercase)
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
                Image(systemName: category.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(category.accentColor)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(category.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(verbatim: countText)
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
