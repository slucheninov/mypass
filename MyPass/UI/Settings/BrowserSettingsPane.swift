import SwiftUI
import AppKit
import SyncKit

struct BrowserSettingsPane: View {
    @EnvironmentObject private var pairingStoreModel: ExtensionPairingStoreModel
    @State private var pairedBrowsers: [PairedBrowser] = []

    // Phase 4: native-messaging host manifest install target. MyPass.app is
    // sandboxed, so the real "~/Library/Application Support/Google/Chrome/
    // NativeMessagingHosts" path can only be reached via a security-scoped
    // bookmark the user grants explicitly here — same pattern as
    // `syncLocalFolderBookmark` above / `LocalFolderBackend.createBookmark`.
    @AppStorage("chromeNativeMessagingDirectoryBookmark") private var chromeNativeMessagingDirectoryBookmarkData: Data?
    // Cannot be discovered automatically — the user copies this from
    // chrome://extensions after loading the unpacked extension (or from the
    // Web Store listing once published). See Task 8/12's plan notes.
    @AppStorage("chromeExtensionID") private var chromeExtensionID: String = ""

    @State private var chromeInstallStatusMessage: String?

    var body: some View {
        Form {
            Section {
                chromeExtensionSection
                SettingsHelperText(text: "Install the native messaging host so the Chrome extension can request matches and save proposals from the browser.")
            } header: {
                Text("Chrome Extension")
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

    private var chromeExtensionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Extension ID (chrome://extensions)", text: $chromeExtensionID)

            if let bookmarkData = chromeNativeMessagingDirectoryBookmarkData, !bookmarkData.isEmpty,
               NativeMessagingHostInstaller.resolveBookmarkedDirectory(bookmarkData: bookmarkData) != nil {
                Text("Folder selected.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder selected.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    chromeNativeMessagingDirectoryBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }

            Button("Install/Update Native Messaging Host") {
                installChromeNativeMessagingHost()
            }
            if let chromeInstallStatusMessage {
                Text(chromeInstallStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installChromeNativeMessagingHost() {
        guard !chromeExtensionID.isEmpty else {
            chromeInstallStatusMessage = "Enter the extension ID."
            return
        }
        guard let bookmarkData = chromeNativeMessagingDirectoryBookmarkData, !bookmarkData.isEmpty,
              let directoryURL = NativeMessagingHostInstaller.resolveBookmarkedDirectory(bookmarkData: bookmarkData) else {
            chromeInstallStatusMessage = "Choose the NativeMessagingHosts folder first."
            return
        }

        guard directoryURL.startAccessingSecurityScopedResource() else {
            chromeInstallStatusMessage = "Could not access the selected folder."
            return
        }
        defer { directoryURL.stopAccessingSecurityScopedResource() }

        do {
            try NativeMessagingHostInstaller.installIfNeeded(
                hostBinaryPath: NativeMessagingHostInstaller.chromeHostBinaryPath,
                extensionID: chromeExtensionID,
                directory: directoryURL
            )
            chromeInstallStatusMessage = "Manifest installed."
        } catch {
            chromeInstallStatusMessage = "Installation failed: \(error)"
        }
    }
}
