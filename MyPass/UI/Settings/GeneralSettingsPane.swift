import SwiftUI
import ServiceManagement

struct GeneralSettingsPane: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("menuBarClickAction") private var menuBarClickAction = "menu"
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    @State private var loginStatusMessage: String?

    private let clickActionOptions = ["menu": "Show a menu"]

    var body: some View {
        Form {
            Section {
                Toggle("Keep MyPass in the menu bar", isOn: $showMenuBarExtra)
                Picker("Click the icon to", selection: $menuBarClickAction) {
                    Text("Show a menu").tag("menu")
                }
                SettingsHelperText(text: "The menu bar icon provides quick access while MyPass runs. Turning it off hides the icon but keeps the main window available from the Dock.")
            } header: {
                Text("Menu Bar")
            }

            Section {
                Toggle("Start MyPass at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginStatusMessage {
                    SettingsHelperText(text: loginStatusMessage)
                }
                SettingsHelperText(text: "MyPass opens in the background at login so the vault and extensions are ready. The vault remains locked until you unlock it manually.")
            } header: {
                Text("Login Item")
            }

            Section {
                ShortcutRecorderField(label: "Show MyPass", storageKey: "shortcutShowMyPass", defaultValue: "")
                HStack {
                    Text("Show Quick Access")
                    Spacer()
                    Text("Coming later")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                ShortcutRecorderField(label: "Lock MyPass", storageKey: "shortcutLockMyPass", defaultValue: "shift+command+L")
                SettingsHelperText(text: "Shortcuts work while MyPass is running. Lock applies only when the vault is unlocked.")
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncLaunchAtLoginFromService()
        }
    }

    private func syncLaunchAtLoginFromService() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            loginStatusMessage = nil
        case .requiresApproval:
            launchAtLogin = false
            loginStatusMessage = "Approval required — open System Settings → General → Login Items and allow MyPass."
        case .notRegistered:
            launchAtLogin = false
            loginStatusMessage = nil
        @unknown default:
            launchAtLogin = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            syncLaunchAtLoginFromService()
        } catch {
            launchAtLogin = false
            loginStatusMessage = "Could not update login item: \(error.localizedDescription)"
        }
    }
}
