import SwiftUI
import AppKit
import SyncKit

/// The "Sync" section of the Vault pane. It is a section hosted by `VaultSettingsPane`, which
/// supplies the single grouped `Form` (and its scrolling) around it, not a pane of its own.
struct SyncSettingsPane: View {
    @AppStorage("secondaryDestination") private var secondaryDestinationRawValue: String = SecondaryDestinationOption.none.rawValue
    @AppStorage("secondaryFolderBookmark") private var secondaryFolderBookmarkData: Data?

    @AppStorage("syncSFTPHost") private var sftpHost: String = ""
    @AppStorage("syncSFTPPort") private var sftpPort: Int = 22
    @AppStorage("syncSFTPUsername") private var sftpUsername: String = ""
    @AppStorage("syncSFTPRemotePath") private var sftpRemotePath: String = "/upload/vault.kdbx"
    @AppStorage("syncSFTPPrivateKeyPath") private var sftpPrivateKeyPath: String = ""
    @AppStorage("syncSFTPCertificatePath") private var sftpCertificatePath: String = ""

    // The private key PEM and its passphrase never go through @AppStorage/
    // UserDefaults — Keychain only (see loadSFTPCredentialsIfAvailable/
    // persistCredentialsToKeychain below). Keep these as plain @State, not
    // @AppStorage, when touching this file.
    @State private var sftpPrivateKeyPEM: String = ""
    @State private var sftpPassphrase: String = ""
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var manualSyncStatusMessage: String?

    @EnvironmentObject private var vaultSession: VaultSession

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private var selectedOption: SecondaryDestinationOption {
        SecondaryDestinationOption(rawValue: secondaryDestinationRawValue) ?? .none
    }

    var body: some View {
        Group {
            Section {
                Picker("Also Sync To", selection: $secondaryDestinationRawValue) {
                    ForEach(SecondaryDestinationOption.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
                // Attached to this one Picker, not to the root `Group`: inside the Vault pane's
                // List-backed grouped Form, a modifier on a `Group` is distributed to every
                // child and Section content flattens into rows, so it could run once per row,
                // and again as the SFTP rows appear after switching "Also Sync To". Each run
                // overwrites the unsaved `sftpUsername` / `sftpPrivateKeyPEM` / `sftpPassphrase`
                // from the Keychain. The Picker sits outside the `switch`, so it is one
                // stable row that appears once with the pane.
                .onAppear { loadSFTPCredentialsIfAvailable() }
                switch selectedOption {
                case .none:
                    EmptyView()
                case .folder:
                    folderSection
                case .sftp:
                    sftpSection
                }
                if selectedOption != .none {
                    Button("Sync Now") {
                        vaultSession.triggerBackgroundSync()
                        manualSyncStatusMessage = "Started…"
                    }
                    if let manualSyncStatusMessage {
                        Text(manualSyncStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsHelperText(text: "Keep an additional copy of the vault in a folder or on an SFTP server, on top of its main location (set in the Location section above). Restart MyPass after changing this.")
            } header: {
                Text("Sync")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = secondaryFolderBookmarkData, !bookmarkData.isEmpty,
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
                    secondaryFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
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
}
