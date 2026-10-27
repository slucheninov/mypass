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
/// The search field is an explicit `NSSearchField` and not `.searchable`: AppKit always places the
/// native search item LAST in the toolbar, so the Import menu could never sit to its right. A
/// single explicit group fixes the order. It still binds `navigationState.searchText`, so the
/// filtering path (`EntryListQuery`) is unchanged.
struct MainWindowToolbarModifier: ViewModifier {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession
    @State private var openExistingVaultURL: URL?
    @State private var searchFocusRequest = 0

    private var currentGroup: KdbxGroup {
        find(uuid: navigationState.selectedGroupID, in: rootGroup) ?? rootGroup
    }

    func body(content: Content) -> some View {
        content
            .background {
                // The command-F shortcut lives in the window content, not in the toolbar item,
                // so it stays active whenever the window is key — including when a narrow
                // window folds the toolbar items into the overflow chevron. `.searchable` used
                // to provide it for free; a representable field does not.
                Button("Find") { searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("Add", systemImage: "plus") {
                        Button("Login") { presentCreate(entryType: .login) }
                        Button("Address") { presentCreate(entryType: .address) }
                        Button("Card") { presentCreate(entryType: .card) }
                        Button("Notes") { presentCreate(entryType: .notes) }
                    }
                    ToolbarSearchField(focusRequest: searchFocusRequest)
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

/// `NSSearchField` standing in for `.searchable` (see `MainWindowToolbarModifier` for why).
///
/// It is a real `NSSearchField`, not a styled SwiftUI `TextField`, so the behaviour people
/// expect from the old `.searchable` field comes for free: Escape clears the text, the cancel
/// button, the focus ring and the accessibility traits. A hand-rolled field had none of those
/// (Escape did nothing). Fixed width so the toolbar's x positions never depend on the typed
/// text.
///
/// `focusRequest` is a counter bumped by the command-F button that the modifier keeps in the
/// window content. Each increase makes the field take first responder. The shortcut must NOT
/// live in the toolbar item: when the window narrows the item collapses into the overflow
/// chevron, its hosting view detaches, and a shortcut owned by it would silently vanish. While
/// the item is collapsed there is no field to focus, so the request is simply a no-op.
struct ToolbarSearchField: NSViewRepresentable {
    @EnvironmentObject var navigationState: NavigationState
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(navigationState: navigationState)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        // Fire the action on every keystroke (not after a pause) so filtering updates exactly as
        // the `.searchable` binding did.
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = navigationState.searchText
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        context.coordinator.lastFocusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.navigationState = navigationState
        // Reflect programmatic changes (for example the state being reset) without fighting the
        // user's typing: only write when the two really differ.
        if field.stringValue != navigationState.searchText {
            field.stringValue = navigationState.searchText
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var navigationState: NavigationState
        var lastFocusRequest = 0

        init(navigationState: NavigationState) {
            self.navigationState = navigationState
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            navigationState.searchText = field.stringValue
        }

        /// Fired by the cancel button and by Escape, which clear the field without a text-change
        /// notification.
        @objc func searchChanged(_ sender: NSSearchField) {
            navigationState.searchText = sender.stringValue
        }
    }
}
