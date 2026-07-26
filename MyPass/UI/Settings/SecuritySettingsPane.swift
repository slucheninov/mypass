import SwiftUI

struct SecuritySettingsPane: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
    @EnvironmentObject private var autoLockController: AutoLockController

    @State private var touchIDEnabled = false

    var body: some View {
        Form {
            Section {
                Stepper("Lock automatically after inactivity: \(Int(autoLockTimeoutMinutes)) min",
                        value: $autoLockTimeoutMinutes, in: 1...120)
                SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
            } header: {
                Text("Auto-Lock")
            }

            Section {
                Toggle("Unlock with Touch ID", isOn: $touchIDEnabled)
                SettingsHelperText(text: "Use Touch ID to unlock without typing your master password; after restart, master password is still required per security model.")
            } header: {
                Text("Touch ID")
            }

            Section {
                Stepper("Clear clipboard after: \(clipboardClearSeconds) s",
                        value: $clipboardClearSeconds, in: 10...120, step: 5)
                SettingsHelperText(text: "Usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.")
            } header: {
                Text("Clipboard")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoLockController.timeout = autoLockTimeoutMinutes * 60
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
    }
}
