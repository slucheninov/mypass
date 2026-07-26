import SwiftUI

struct BackupsSettingsPane: View {
    @AppStorage("backupCount") private var backupCount: Int = 10

    var body: some View {
        Form {
            Section {
                Stepper("Keep last: \(backupCount)", value: $backupCount, in: 1...50)
                SettingsHelperText(text: "Rotate local backup copies of the vault file so you can recover from a corrupted save.")
            } header: {
                Text("Backups")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
