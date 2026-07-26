import SwiftUI
import AppKit
import MyPassKit
import SyncKit

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue
    @AppStorage("syncLocalFolderBookmark") private var syncLocalFolderBookmarkData: Data?

    // SFTP non-secret fields — host/port/username/remotePath/paths only.
    // The private key PEM and its passphrase NEVER go through @AppStorage/
    // UserDefaults — they are stored exclusively via CredentialKeychainStore
    // (Task 9), per the design doc's security stance that secret material
    // belongs in Keychain, not plist-backed UserDefaults.
    @AppStorage("syncSFTPHost") private var sftpHost: String = ""
    @AppStorage("syncSFTPPort") private var sftpPort: Int = 22
    @AppStorage("syncSFTPUsername") private var sftpUsername: String = ""
    @AppStorage("syncSFTPRemotePath") private var sftpRemotePath: String = "/upload/vault.kdbx"
    @AppStorage("syncSFTPPrivateKeyPath") private var sftpPrivateKeyPath: String = ""
    // UI-only bookkeeping — known gap: not wired into SFTPBackendConfiguration
    // (Task 10 has no certificate field), kept only so the chosen path survives
    // across Settings reopens.
    @AppStorage("syncSFTPCertificatePath") private var sftpCertificatePath: String = ""

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

    @State private var sftpPrivateKeyPEM: String = ""
    @State private var sftpPassphrase: String = ""
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var chromeInstallStatusMessage: String?

    @State private var iCloudContainerAvailable: Bool = true
    @State private var iCloudContainerCheckMessage: String?
    @State private var manualSyncStatusMessage: String?

    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private var selectedOption: SyncBackendOption {
        SyncBackendOption(rawValue: syncBackendRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section {
                Stepper("Timeout: \(Int(autoLockTimeoutMinutes)) min", value: $autoLockTimeoutMinutes, in: 1...120)
                SettingsHelperText(text: "Lock the vault automatically after inactivity so passwords stay protected when you step away.")
                SettingsHelperText(text: "Copied usernames and passwords are cleared from the clipboard after 30 seconds when copied from an entry.")
            } header: {
                Text("Auto-Lock")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                Stepper("Keep last: \(backupCount)", value: $backupCount, in: 1...50)
                SettingsHelperText(text: "Rotate local backup copies of your vault file so you can recover from a corrupted save.")
            } header: {
                Text("Backups")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                Picker("Backend", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
                switch selectedOption {
                case .local:
                    localFolderSection
                case .iCloud:
                    iCloudSection
                case .sftp:
                    sftpSection
                }
                Button("Sync Now") {
                    vaultSession.triggerBackgroundSync()
                    manualSyncStatusMessage = "Started…"
                }
                if let manualSyncStatusMessage {
                    Text(manualSyncStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingsHelperText(text: "Choose where the encrypted vault is mirrored and run an immediate sync when you change devices or paths.")
            } header: {
                Text("Sync")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                chromeExtensionSection
                SettingsHelperText(text: "Install the native messaging host so the Chrome extension can request matches and save proposals from the browser.")
            } header: {
                Text("Chrome Extension")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420)
        .onAppear {
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshICloudStatus()
            loadSFTPCredentialsIfAvailable()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .onChange(of: syncBackendRawValue) { _, _ in
            refreshICloudStatus()
        }
    }

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = syncLocalFolderBookmarkData, !bookmarkData.isEmpty,
               SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData) != nil {
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
                    syncLocalFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }
        }
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

    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if iCloudContainerAvailable {
                Text("iCloud container is available.")
                    .foregroundStyle(.secondary)
            } else {
                Text(iCloudContainerCheckMessage ?? "iCloud Drive is unavailable — sign in to iCloud and enable iCloud Drive in System Settings.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sftpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Host", text: $sftpHost)
            Stepper("Port: \(sftpPort)", value: $sftpPort, in: 1...65535)
            TextField("Username", text: $sftpUsername)
                .onChange(of: sftpUsername) { _, _ in persistCredentialsToKeychain() }
            TextField("Remote Path", text: $sftpRemotePath)
            SecureField("Key Passphrase (if any)", text: $sftpPassphrase)
                .onChange(of: sftpPassphrase) { _, _ in persistCredentialsToKeychain() }

            HStack {
                Text(sftpPrivateKeyPath.isEmpty ? "No key selected" : sftpPrivateKeyPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose Private Key…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        sftpPrivateKeyPath = url.path
                        if let contents = try? String(contentsOf: url, encoding: .utf8) {
                            sftpPrivateKeyPEM = contents
                            persistCredentialsToKeychain()
                        }
                    }
                }
            }

            HStack {
                Text(sftpCertificatePath.isEmpty ? "No certificate selected (optional)" : sftpCertificatePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose Certificate…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        // Path-only, UI bookkeeping — known gap: not yet wired into any
                        // real SSH authentication.
                        sftpCertificatePath = url.path
                    }
                }
            }

            Button("Test Connection") {
                testSFTPConnection()
            }
            switch connectionTestState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label("Connection successful", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadSFTPCredentialsIfAvailable() {
        guard !sftpHost.isEmpty,
              let credentials = try? CredentialKeychainStore().loadCredentials(forHost: sftpHost) else { return }
        sftpUsername = credentials.username
        sftpPrivateKeyPEM = credentials.privateKeyPEM
        sftpPassphrase = credentials.privateKeyPassphrase ?? ""
    }

    private func persistCredentialsToKeychain() {
        guard !sftpHost.isEmpty, !sftpPrivateKeyPEM.isEmpty else { return }
        let credentials = SFTPCredentials(
            username: sftpUsername,
            privateKeyPEM: sftpPrivateKeyPEM,
            privateKeyPassphrase: sftpPassphrase.isEmpty ? nil : sftpPassphrase
        )
        try? CredentialKeychainStore().store(credentials, forHost: sftpHost)
    }

    private func testSFTPConnection() {
        connectionTestState = .testing
        let configuration = SyncBackendResolver.buildSFTPConfiguration(
            host: sftpHost,
            port: sftpPort,
            username: sftpUsername,
            remotePath: sftpRemotePath,
            credentials: SFTPCredentials(
                username: sftpUsername,
                privateKeyPEM: sftpPrivateKeyPEM,
                privateKeyPassphrase: sftpPassphrase.isEmpty ? nil : sftpPassphrase
            )
        )
        let tester = SFTPConnectionTester(configurationProvider: { configuration })
        DispatchQueue.global(qos: .userInitiated).async {
            let result = tester.testConnection()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    connectionTestState = .success
                case .failure(let error):
                    connectionTestState = .failure("\(error)")
                }
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
                hostBinaryPath: NativeMessagingHostInstaller.debugChromeHostBinaryPath,
                extensionID: chromeExtensionID,
                directory: directoryURL
            )
            chromeInstallStatusMessage = "Manifest installed."
        } catch {
            chromeInstallStatusMessage = "Installation failed: \(error)"
        }
    }

    private func refreshICloudStatus() {
        guard selectedOption == .iCloud else { return }
        do {
            _ = try iCloudBackend(relativePath: "vault.kdbx")
            iCloudContainerAvailable = true
            iCloudContainerCheckMessage = nil
        } catch iCloudBackendError.containerUnavailable {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "iCloud Drive is unavailable — sign in to iCloud and enable iCloud Drive in System Settings."
        } catch {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "Could not verify iCloud container: \(error)"
        }
    }
}
