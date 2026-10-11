import AppKit
import SwiftUI

struct BrowserSettingsPane: View {
    @EnvironmentObject private var pairingStoreModel: ExtensionPairingStoreModel
    @ObservedObject private var diagnostics = BrowserDiagnosticsStore.shared
    @State private var pairedBrowsers: [PairedBrowser] = []
    @State private var showingHelp = false
    @State private var revokeError: String?
    /// This is the canonical value used by the bridge. Browser reports are snapshots
    /// and must never overwrite this preference with a delayed observation.
    @AppStorage("passkeyProxyEnabled") private var passkeyProxyEnabled = false

    var body: some View {
        Form {
            Section("Passkeys") {
                Toggle("Use MyPass for Chrome passkeys", isOn: $passkeyProxyEnabled)
                SettingsHelperText(text: passkeyProxyEnabled
                    ? "Reopen the MyPass browser extension to apply this setting. Then use the website’s sign-in or create-passkey button and approve in MyPass. While MyPass handles passkeys, Chrome’s other passkey choices are unavailable."
                    : "Turn this on to save and use passkeys in MyPass. Reopen the browser extension after changing this setting.")
            }

            Section("Browser setup") {
                Text("Use MyPass as your password manager")
                    .font(.headline)
                SettingsHelperText(text: "Disable other password manager extensions and browser save prompts in every profile where you use MyPass. Open the MyPass extension and choose Check this browser to review that profile.")
                Button("How to disable other managers") { showingHelp = true }
                SettingsHelperText(text: "The check reads browser settings and recognized extensions. It cannot verify all autofill, passkey or macOS providers. Nothing is disabled automatically.")
            }

            Section("Paired browsers") {
                if let revokeError { Text(revokeError).foregroundStyle(.red) }
                if pairedBrowsers.isEmpty {
                    Text("No paired browsers. Open the MyPass browser extension to connect.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pairedBrowsers) { browser in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(browser.label).font(.headline)
                            Spacer()
                            Button("Revoke") {
                                do {
                                    try pairingStoreModel.store.remove(id: browser.id)
                                    revokeError = nil
                                    diagnostics.remove(browserID: browser.id)
                                    pairedBrowsers = pairingStoreModel.refresh()
                                } catch {
                                    revokeError = "Could not revoke this browser. Try again."
                                }
                            }
                        }
                        Text("Paired " + browser.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if let snapshot = diagnostics.snapshots[browser.id] {
                            Text(snapshot.passkeyStatus)
                            Text(snapshot.passwordSavingStatus)
                            Text(snapshot.managerStatus)
                            Text("Last report received " + snapshot.receivedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                            SettingsHelperText(text: "This is the last reported state, not a live check. Reopen the extension and choose Check this browser after changing another manager.")
                        } else {
                            SettingsHelperText(text: "No report received in this app session. Open this browser’s MyPass extension and choose Check this browser.")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { pairedBrowsers = pairingStoreModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pairedBrowsers = pairingStoreModel.refresh()
        }
        .sheet(isPresented: $showingHelp) { BrowserManagersHelpSheet() }
    }
}
