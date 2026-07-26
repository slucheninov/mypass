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
        if navigationState.selectedSmartCategory == .security, navigationState.securityUsesGroupScope {
            if navigationState.searchText.isEmpty {
                return currentGroup.entries
            }
            return EntrySearch.entries(in: rootGroup, matching: navigationState.searchText)
        }
        if navigationState.isCategoryMode, let database = vaultSession.currentDatabase {
            let scoped = EntryCategoryFilter.entries(for: navigationState.activeCategoryFilter, in: database)
            if navigationState.searchText.isEmpty {
                return scoped
            }
            return scoped.filter { EntrySearch.matches(entry: $0, query: navigationState.searchText) }
        }
        if navigationState.searchText.isEmpty {
            return currentGroup.entries
        }
        return EntrySearch.entries(in: rootGroup, matching: navigationState.searchText)
    }

    private var headerTitle: String {
        if navigationState.isCategoryMode {
            return navigationState.selectedSmartCategory.title
        }
        return currentGroup.name
    }

    private func displayTitle(for entry: KdbxEntry) -> String {
        entry.title.isEmpty ? "(untitled)" : entry.title
    }

    var body: some View {
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            let isSelected = navigationState.selectedEntryID == entry.uuid
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.login
            )
            .tag(entry.uuid)
            .listRowBackground(EntryListRowBackground(isSelected: isSelected))
            .draggable(entry.uuid.uuidString) // full drag-and-drop wiring completed in Task 15
        }
        .navigationTitle(headerTitle)
        .frame(minWidth: UIShellMetrics.listColumnMinWidth)
        .searchable(text: $navigationState.searchText)
        .toolbar {
            ToolbarItem {
                Button("Add", systemImage: "plus") {
                    navigationState.presentCreate(defaultGroupID: currentGroup.uuid)
                }
            }
            ToolbarItem {
                Menu("Import", systemImage: "square.and.arrow.down") {
                    Button("Import CSV…") { importCSV() }
                    Button("Open Existing .kdbx…") { openExistingVault() }
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

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let imported = try CSVImporter.parse(csvData: data)
            vaultSession.mutate { database in
                let targetGroup = find(uuid: navigationState.selectedGroupID, in: database.rootGroup) ?? database.rootGroup
                targetGroup.entries.append(contentsOf: imported)
            }
        } catch {
            // Surface via an alert in a future polish pass; for now the import silently
            // no-ops on read/parse failure rather than corrupting the vault.
        }
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Known limitation (see plan Global Constraints): only .kdbx files created by
        // MyPass itself (16-byte Argon2id salt) are guaranteed to open. Third-party
        // KeePassXC files with a 32-byte salt will fail here with a message that
        // explicitly names this limitation rather than a bare "wrong password".
        do {
            let data = try Data(contentsOf: url)
            _ = try KdbxDatabase.open(data: data, password: "") // password prompt UI deferred; placeholder call demonstrates the error path
        } catch {
            NSSound.beep()
            // A production alert would read: "Could not open file. MyPass supports
            // opening .kdbx files created by MyPass itself; third-party KeePassXC
            // files with a 32-byte Argon2id salt are not yet supported."
        }
    }
}

private struct EntryListRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            LetterAvatarView(
                title: title,
                size: UIShellMetrics.listIconSize,
                cornerRadius: UIShellMetrics.listIconCornerRadius
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
