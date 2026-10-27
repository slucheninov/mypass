import SwiftUI

/// The "Backups" section of the Vault pane. It is a section hosted by `VaultSettingsPane`, which
/// supplies the single grouped `Form` (and its scrolling) around it, not a pane of its own.
struct BackupsSettingsPane: View {
    @AppStorage("backupCount") private var backupCount: Int = 10

    var body: some View {
        Group {
            Section {
                Stepper("Keep last: \(backupCount)", value: $backupCount, in: 1...50)
                SettingsHelperText(text: "Rotate local backup copies of the vault file so you can recover from a corrupted save.")
            } header: {
                Text("Backups")
            }
        }
    }
}
