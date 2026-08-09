import SwiftUI

struct BrowserSettingsPane: View {
    @EnvironmentObject private var pairingStoreModel: ExtensionPairingStoreModel
    @State private var pairedBrowsers: [PairedBrowser] = []
    /// The same `UserDefaults` key `ExtensionBridgeService` reads in
    /// `getPasskeyProxyStatus` and writes in `setPasskeyProxyEnabled` — the two
    /// surfaces converge on one value rather than syncing two.
    @AppStorage("passkeyProxyEnabled") private var passkeyProxyEnabled = false

    var body: some View {
        Form {
            Section {
                // No live push channel exists from app to extension: a change here reaches
                // Chrome the next time it calls `getPasskeyProxyStatus` — service-worker
                // wake or popup reopen. That is the lifecycle plan C designed, not a gap.
                Toggle("Use MyPass for Chrome passkeys", isOn: $passkeyProxyEnabled)
                SettingsHelperText(
                    text: "While enabled, MyPass becomes the exclusive passkey provider for Chrome — "
                        + "iCloud Keychain and security keys won't be offered for passkey sign-in until you "
                        + "turn this off. Changes take effect the next time Chrome's extension checks in "
                        + "(on browser restart or when you reopen the popup)."
                )
            } header: {
                Text("Passkeys")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                if pairedBrowsers.isEmpty {
                    Text("No paired browsers.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedBrowsers) { browser in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(browser.label)
                                Text(browser.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                try? pairingStoreModel.store.remove(id: browser.id)
                                pairedBrowsers = pairingStoreModel.refresh()
                            }
                        }
                    }
                }
            } header: {
                Text("Paired browsers")
                    .font(.system(size: 13, weight: .semibold))
            }
            .onAppear {
                pairedBrowsers = pairingStoreModel.refresh()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
