import SwiftUI
import AppKit
import MyPassKit

/// The one and only window-toolbar content of the main window: "+" Add menu, then the search
/// field, then the Import menu, in a single trailing group that is identical in every state
/// (nothing selected, scope overview, entry browse, edit, Recycle Bin).
///
/// It is attached to the `NavigationSplitView` itself rather than to a column. A toolbar
/// declared inside one column's content comes and goes with that column's view identity, which
/// is what made the items jump around when the detail column changed. Entry-level actions
/// (Edit, the favourite star, Cancel/Save, the ⋮ menu) live in in-column rows instead — see
/// `EntryActionRow` — so nothing else may contribute window-toolbar items.
///
/// The search field is an explicit `TextField` and not `.searchable`: AppKit always places the
/// native search item LAST in the toolbar, so the Import menu could never sit to its right. A
/// single explicit group fixes the order. It still binds `navigationState.searchText`, so the
/// filtering path (`EntryListQuery`) is unchanged.
struct MainWindowToolbarModifier: ViewModifier {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession
    @State private var openExistingVaultURL: URL?

    private var currentGroup: KdbxGroup {
        find(uuid: navigationState.selectedGroupID, in: rootGroup) ?? rootGroup
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("Add", systemImage: "plus") {
                        Button("Login") { presentCreate(entryType: .login) }
                        Button("Address") { presentCreate(entryType: .address) }
                        Button("Card") { presentCreate(entryType: .card) }
                        Button("Notes") { presentCreate(entryType: .notes) }
                    }
                    ToolbarSearchField()
                    Menu("Import", systemImage: "square.and.arrow.down") {
                        Button("Import CSV…") { importCSV() }
                        Button("Open Existing .kdbx…") { openExistingVault() }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { openExistingVaultURL != nil },
                set: { if !$0 { openExistingVaultURL = nil } }
            )) {
                if let url = openExistingVaultURL {
                    OpenExistingVaultSheet(
                        fileURL: url,
                        onSuccess: { database, password in
                            openExistingVaultURL = nil
                            completeOpenExistingVault(fileURL: url, password: password, database: database)
                        },
                        onCancel: { openExistingVaultURL = nil }
                    )
                }
            }
    }

    private func presentCreate(entryType: EntryType) {
        let binUUID = vaultSession.currentDatabase?.recycleBinGroupUUID
        let defaultGroupID = GroupTreeOperations.clampedDefaultGroupID(
            currentGroup.uuid,
            in: rootGroup,
            recycleBinGroupUUID: binUUID
        )
        navigationState.presentCreate(defaultGroupID: defaultGroupID, entryType: entryType)
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
        openExistingVaultURL = url
    }

    /// Called once `OpenExistingVaultSheet` has already proven `password`
    /// opens the file at `fileURL` — creates the security-scoped bookmark
    /// this session needs to keep reading `fileURL` across launches, then
    /// hands off to `VaultSession.retargetToOpenExistingVault` to actually
    /// switch the primary vault over.
    private func completeOpenExistingVault(fileURL: URL, password: String, database: KdbxDatabase) {
        do {
            let bookmark = try LocalFileVaultStore.createFileBookmark(for: fileURL)
            try vaultSession.retargetToOpenExistingVault(
                fileURL: fileURL,
                bookmarkData: bookmark,
                password: password,
                database: database
            )
        } catch {
            NSSound.beep()
            // A production alert would read: "Could not switch to this vault
            // file: \(error)".
        }
    }
}

/// Plain text field standing in for `.searchable` (see `MainWindowToolbarModifier` for why).
/// Fixed width so the toolbar's x positions never depend on the typed text.
struct ToolbarSearchField: View {
    @EnvironmentObject var navigationState: NavigationState
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $navigationState.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !navigationState.searchText.isEmpty {
                Button {
                    navigationState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .background {
            // Zero-size, invisible button whose only job is to own the command-F shortcut.
            // `.searchable` used to provide it for free; a plain TextField does not.
            Button("Find") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
