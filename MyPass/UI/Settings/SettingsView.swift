import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsPane.storageKey) private var selectedPaneRaw: String = SettingsPane.general.rawValue
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private var selectedPane: SettingsPane {
        SettingsPane.resolve(storedRaw: selectedPaneRaw)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedPane },
                set: { selectedPaneRaw = $0.rawValue }
            )) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } detail: {
            paneContent(for: selectedPane)
                .frame(minWidth: 480)
                .navigationTitle(selectedPane.detailTitle)
        }
        .frame(minWidth: 660, minHeight: 420)
        // Keep this when SettingsView is restructured: it is how SettingsWindowPlacer finds the
        // Settings NSWindow (not by title, which gets localized, nor SwiftUI's private id), so
        // that window can be centred over the main window and kept on the current Space.
        .background(SettingsWindowAccessor())
        // A profile that last left Settings on Vault Location, Sync or Backups still has that
        // legacy name stored. `selectedPane` already resolves it to Vault; this writes the
        // resolved raw value back once, so the legacy name is migrated permanently instead of
        // being re-resolved on every launch.
        .onAppear {
            if selectedPaneRaw != selectedPane.rawValue {
                selectedPaneRaw = selectedPane.rawValue
            }
        }
    }

    @ViewBuilder
    private func paneContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsPane()
        case .vault:
            VaultSettingsPane()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        case .security:
            SecuritySettingsPane()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        case .browser:
            BrowserSettingsPane()
                .environmentObject(AppDelegate.extensionPairingStoreModel!)
        case .appearance:
            AppearanceSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }
}
