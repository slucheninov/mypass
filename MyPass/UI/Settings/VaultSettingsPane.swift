import SwiftUI

/// The merged Vault pane: Location, Sync and Backups as three sections of ONE grouped `Form`.
/// A single form scrolls as a whole, so at the 420pt minimum window height the lower sections
/// (and the "Keep last" stepper) stay reachable instead of being clipped, which three stacked
/// forms with their own padding would do. The section views keep their names and environment
/// requirements: `VaultLocationSettingsPane` and `SyncSettingsPane` read `VaultSession` from the
/// environment of this pane (`SettingsView` also passes `AutoLockController`, as it did for Sync).
struct VaultSettingsPane: View {
    var body: some View {
        Form {
            VaultLocationSettingsPane()
            SyncSettingsPane()
            BackupsSettingsPane()
        }
        .formStyle(.grouped)
        .padding()
    }
}
