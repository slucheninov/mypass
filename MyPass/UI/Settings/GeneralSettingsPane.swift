import SwiftUI
import ServiceManagement

struct GeneralSettingsPane: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("menuBarClickAction") private var menuBarClickAction = "menu"
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("updateCheckEnabled") private var updateCheckEnabled = true
    @EnvironmentObject private var updateChecker: AppUpdateChecker

    @State private var loginStatusMessage: String?
    @State private var isSyncingLoginItem = false

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
                        guard !isSyncingLoginItem else { return }
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
                Toggle("Check for updates automatically", isOn: $updateCheckEnabled)
                    .onChange(of: updateCheckEnabled) { _, _ in
                        updateChecker.enabledDidChange()
                    }
                SettingsHelperText(text: "When on, MyPass contacts api.github.com a few seconds after launch and then once a day to read the tag of the latest release. Nothing else is sent: no account, vault or device information.")
                LabeledContent("Current version", value: updateChecker.currentVersion?.description ?? "Unknown")
                LabeledContent("Last checked", value: lastCheckedText)
                HStack {
                    Button("Check now") {
                        Task { await updateChecker.check(manual: true) }
                    }
                    .disabled(updateChecker.status == .checking)
                    updateStatusView
                }
            } header: {
                Text("Updates")
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

    private var lastCheckedText: String {
        guard let lastRun = updateChecker.lastRun else { return "Never" }
        return RelativeDateTimeFormatter().localizedString(for: lastRun, relativeTo: Date())
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateChecker.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Text("You have the latest version").foregroundStyle(.secondary)
        case .available(let release):
            Text("MyPass \(release.version.description) is available")
            Button("View release") { NSWorkspace.shared.open(release.url) }
                .buttonStyle(.link)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func syncLaunchAtLoginFromService() {
        isSyncingLoginItem = true
        defer { isSyncingLoginItem = false }

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
            isSyncingLoginItem = true
            launchAtLogin = false
            loginStatusMessage = "Could not update login item: \(error.localizedDescription)"
            isSyncingLoginItem = false
        }
    }
}
