import SwiftUI
import AppKit
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    private var currentGroup: KdbxGroup {
        find(uuid: navigationState.selectedGroupID, in: rootGroup) ?? rootGroup
    }

    private var displayedEntries: [KdbxEntry] {
        EntryListQuery.entries(root: rootGroup, database: vaultSession.currentDatabase, navigation: navigationState)
    }

    /// A plain `String` for `.navigationTitle`, so the category title is resolved here with
    /// `String(localized:)` and the group name goes through `displayName` (vault names verbatim,
    /// only the Recycle Bin localized).
    private var headerTitle: String {
        if navigationState.isCategoryMode {
            return String(localized: navigationState.selectedSmartCategory.title)
        }
        return GroupTreeOperations.displayName(for: currentGroup, recycleBinGroupUUID: vaultSession.currentDatabase?.recycleBinGroupUUID)
    }

    private func displayTitle(for entry: KdbxEntry) -> String {
        entry.displayTitle
    }

    private func toggleFavorite(_ entry: KdbxEntry) {
        vaultSession.mutate { database in
            var updated = entry
            updated.isFavorite.toggle()
            updated.lastModificationTime = Date()
            EntryPersistence.replaceEntry(updated, in: database.rootGroup)
        }
    }

    var body: some View {
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            let isSelected = navigationState.selectedEntryID == entry.uuid
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.entryType == .address ? entry.addressSummary : entry.login,
                entryType: entry.entryType
            )
            .tag(entry.uuid)
            .listRowBackground(EntryListRowBackground(isSelected: isSelected))
            .draggable(entry.uuid.uuidString) // full drag-and-drop wiring completed in Task 15
            .contextMenu {
                Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    toggleFavorite(entry)
                }
            }
        }
        .navigationTitle(headerTitle)
        .frame(minWidth: UIShellMetrics.listColumnMinWidth)
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

private struct EntryListRow: View {
    let title: String
    let subtitle: String
    let entryType: EntryType

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch entryType {
        case .address:
            templateIconTile(systemName: "house")
        case .card:
            templateIconTile(systemName: "creditcard")
        case .notes:
            templateIconTile(systemName: "note.text")
        case .login:
            LetterAvatarView(
                title: title,
                size: UIShellMetrics.listIconSize,
                cornerRadius: UIShellMetrics.listIconCornerRadius
            )
        }
    }

    private func templateIconTile(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: UIShellMetrics.listIconCornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: UIShellMetrics.listIconSize, height: UIShellMetrics.listIconSize)
            .overlay(
                Image(systemName: systemName)
                    .foregroundStyle(.secondary)
            )
    }
}

private struct EntryListRowBackground: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            HStack(spacing: 0) {
                Color.accentColor
                    .frame(width: UIShellMetrics.selectionAccentBarWidth)
                Color.accentColor.opacity(0.12)
            }
        } else {
            Color.clear
        }
    }
}
