import SwiftUI
import AppKit
import MyPassKit

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var deviceUnlockPromptCoordinator: DeviceUnlockPromptCoordinator
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lastDeviceUnlockTimestamp") private var lastDeviceUnlockTimestamp: Double = 0
    @AppStorage("lastFullPasswordEntryTimestamp") private var lastFullPasswordEntryTimestamp: Double = 0

    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isFirstRun = false
    @State private var vaultStatus: VaultFileStatus = .noVault
    @State private var activeSheet: UnlockSheet?
    /// Folder access from "Find .kdbx Files…", kept open until the open flow it leads to ends.
    @State private var folderGrant: FolderAccessGrant?
    @FocusState private var passwordFocused: Bool

    private enum UnlockSheet: Identifiable {
        case find(folder: URL)
        case open(fileURL: URL)

        var id: String {
            switch self {
            case .find(let folder): return "find:" + folder.path
            case .open(let fileURL): return "open:" + fileURL.path
            }
        }
    }

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    /// A `String` built with `String(localized:)` (not a literal handed to `Button`): the label is
    /// computed from two toggles, and the `(false, false)` case is empty, which a
    /// `LocalizedStringResource` would extract into the catalog as an empty key.
    private var deviceUnlockButtonLabel: String {
        switch (touchIDEnabled, macPasswordEnabled) {
        case (true, true): return String(localized: "Unlock with Touch ID or Password", comment: "Unlock screen: device unlock button when both Touch ID and Mac password are enabled")
        case (true, false): return String(localized: "Touch ID", comment: "Unlock screen: device unlock button label")
        case (false, true): return String(localized: "Unlock with Mac Password", comment: "Unlock screen: device unlock button when only the Mac password is enabled")
        case (false, false): return ""
        }
    }

    private var deviceUnlockButtonSymbol: String {
        macPasswordEnabled && !touchIDEnabled ? "key.fill" : "touchid"
    }

    private var canShowDeviceUnlockButton: Bool {
        guard touchIDEnabled || macPasswordEnabled else { return false }
        guard DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore) else { return false }
        return UnlockWindowPolicy.deviceAuthAllowed(
            now: Date(),
            lastDeviceUnlock: lastDeviceUnlockTimestamp > 0 ? Date(timeIntervalSince1970: lastDeviceUnlockTimestamp) : nil,
            lastFullPasswordEntry: lastFullPasswordEntryTimestamp > 0 ? Date(timeIntervalSince1970: lastFullPasswordEntryTimestamp) : nil,
            deviceWindow: unlockWithDeviceWindow,
            accountPasswordWindow: requireAccountPasswordWindow
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MyPass")
                .font(.system(size: 28, weight: .semibold))

            Image("BrandKey")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            vaultStatusView

            if isFirstRun {
                VStack(spacing: 4) {
                    Text("Choose a master password for this vault.")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Write it down or store it somewhere safe. There is no way to change or recover it later — not even if you forget it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }

            SecureField(isFirstRun ? "Choose a Master Password" : "Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .focused($passwordFocused)
                .onSubmit(attemptUnlock)

            KeyboardLayoutIndicator()

            if let errorMessage {
                // Already localized where it is set.
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: 320)

            if canShowDeviceUnlockButton {
                Button(deviceUnlockButtonLabel, systemImage: deviceUnlockButtonSymbol) {
                    attemptDeviceUnlock()
                }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: 16) {
                Button("Open Existing .kdbx…") { openExistingVault() }
                Button("Find .kdbx Files…") { findVaultFiles() }
                // A new vault can only be created where none exists yet. With an existing
                // default copy in use as the fallback, the password field unlocks that copy.
                if isFirstRun, !hasVaultFile {
                    Button("Create New Vault") { createNewVault() }
                }
            }
            .buttonStyle(.link)

            Text(isFirstRun
                 ? "This password protects your vault. Remember it — it cannot be changed or reset later."
                 : "Vault is locked. Enter your master password or use Touch ID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isFirstRun = (try? vaultSession.loadVaultData()) == nil
            vaultStatus = vaultSession.vaultFileStatus
            // Appearing never prompts by itself. The one exception is an explicit
            // extension Unlock that arrived while the window was closed, before this
            // view existed — `MyPassApp.onUnlockRequested` recorded it on the
            // coordinator and the notification below was dropped for lack of an observer.
            // Consume first and let `attemptDeviceUnlock()` decide: when device unlock is
            // unavailable it shows the "unavailable" message (the user did press Unlock
            // in the extension) instead of silently skipping and leaving a still-fresh
            // request behind to fire after a later Lock.
            if !isFirstRun, deviceUnlockPromptCoordinator.consumeExtensionUnlockRequest() {
                attemptDeviceUnlock()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDeviceUnlockPrompt)) { _ in
            // `MyPassApp.onUnlockRequested` already calls `MainWindowActivator.request()`
            // right before posting this notification, so there is nothing left to do
            // here when the request was already consumed — the window is already coming
            // forward either way. Not guarded on `canShowDeviceUnlockButton`: the user
            // pressed Unlock in the extension, so they get the same "Device unlock is
            // unavailable..." feedback as for a button press.
            guard deviceUnlockPromptCoordinator.consumeExtensionUnlockRequest() else { return }
            attemptDeviceUnlock()
        }
        .sheet(item: $activeSheet, onDismiss: {
            // Covers every way out of the open flow (success, Cancel, Esc). A hand-off from the
            // find sheet to the open sheet swaps `activeSheet` without dismissing, so the grant
            // survives exactly as long as it is needed.
            if case .open = activeSheet { return }
            folderGrant?.release()
            folderGrant = nil
        }) { sheet in
            switch sheet {
            case .find(let folder):
                FindVaultFilesSheet(
                    folder: folder,
                    connectedFile: vaultSession.currentPrimaryStore.primaryVaultFileURL,
                    onSelect: { activeSheet = .open(fileURL: $0) },
                    onCancel: { activeSheet = nil }
                )
            case .open(let url):
                OpenExistingVaultSheet(
                    fileURL: url,
                    onSuccess: { database, openedPassword in
                        completeOpenExistingVault(fileURL: url, password: openedPassword, database: database)
                        activeSheet = nil
                    },
                    onCancel: { activeSheet = nil }
                )
            }
        }
    }

    private var hasVaultFile: Bool {
        if case .connected = vaultStatus { return true }
        return false
    }

    /// Always visible, so it is clear which file a master password will be checked against (or
    /// that there is none). Red is reserved for "no usable vault file".
    @ViewBuilder
    private var vaultStatusView: some View {
        switch vaultStatus {
        case .connected(let info):
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.fileName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: info.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = info.summary {
                        Text(verbatim: summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
        case .noVault:
            Text("No vault file selected. Choose an existing .kdbx file or create a new one.")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        case .missing(let path):
            Group {
                if let path {
                    Text("The vault file at \(VaultFileInfo.abbreviatedPath(path)) can't be found. Choose it again or create a new vault.")
                } else {
                    Text("Your vault file can't be found. Choose it again or create a new vault.")
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }
    }

    /// Creation itself is the existing first-run path (the master password unlocks into a new
    /// vault); this just points the user at it.
    private func createNewVault() {
        passwordFocused = true
        if !password.isEmpty { attemptUnlock() }
    }

    private func findVaultFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = RealHomeDirectory.url
        panel.prompt = String(localized: "Search", comment: "Open panel: confirm button when choosing the folder to search for .kdbx files")
        panel.message = String(localized: "MyPass will look for .kdbx files in the folder you choose. Choose your home folder to search everywhere.", comment: "Open panel: explains the folder choice for finding vault files")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        // One-shot access for the scan and the open flow; the home folder is never bookmarked.
        folderGrant?.release()
        folderGrant = FolderAccessGrant(url: folder)
        activeSheet = .find(folder: folder)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
            let now = Date().timeIntervalSince1970
            lastDeviceUnlockTimestamp = now
            lastFullPasswordEntryTimestamp = now
        } catch {
            errorMessage = String(localized: "Incorrect password or corrupted file.", comment: "Unlock screen: inline message")
        }
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        activeSheet = .open(fileURL: url)
    }

    /// Called once `OpenExistingVaultSheet` has already proven `password`
    /// opens the file at `fileURL` — creates the security-scoped bookmark
    /// this session needs to keep reading `fileURL` across launches, then
    /// hands off to `VaultSession.retargetToOpenExistingVault`, which both
    /// retargets and publishes the unlocked database (so the app transitions
    /// straight from locked to this vault without a second unlock step).
    private func completeOpenExistingVault(fileURL: URL, password: String, database: KdbxDatabase) {
        do {
            let bookmark = try LocalFileVaultStore.createFileBookmark(for: fileURL)
            try vaultSession.retargetToOpenExistingVault(
                fileURL: fileURL,
                bookmarkData: bookmark,
                password: password,
                database: database
            )
            let now = Date().timeIntervalSince1970
            lastDeviceUnlockTimestamp = now
            lastFullPasswordEntryTimestamp = now
        } catch {
            errorMessage = String(localized: "Could not switch to this vault file.", comment: "Unlock screen: inline message")
            vaultStatus = vaultSession.vaultFileStatus
        }
    }

    /// Every device-unlock attempt is explicit — a press of the button, or a consumed
    /// extension Unlock request — so failures are always surfaced instead of silently
    /// doing nothing. Returns whether a prompt was actually started. `false` (no
    /// authenticator call made) means the coordinator suppressed it because another
    /// prompt is already in flight, or that device unlock is unavailable (in which case
    /// the error message is shown).
    @discardableResult
    private func attemptDeviceUnlock() -> Bool {
        guard deviceUnlockPromptCoordinator.requestExplicitPrompt() else { return false }

        guard canShowDeviceUnlockButton else {
            deviceUnlockPromptCoordinator.promptFinished()
            errorMessage = String(localized: "Device unlock is unavailable. Enter your master password.", comment: "Unlock screen: inline message")
            return false
        }
        guard let accessControl = DeviceUnlockAccessControl.forToggles(
            touchIDEnabled: touchIDEnabled,
            macPasswordEnabled: macPasswordEnabled
        ) else {
            deviceUnlockPromptCoordinator.promptFinished()
            errorMessage = String(localized: "Device unlock is unavailable. Enter your master password.", comment: "Unlock screen: inline message")
            return false
        }
        DeviceUnlockAuthenticator.authenticate(accessControl: accessControl) { success in
            defer { deviceUnlockPromptCoordinator.promptFinished() }
            guard success else {
                // The attempt was deliberate, so a cancelled or failed Touch ID gets
                // feedback instead of silently doing nothing.
                errorMessage = String(localized: "Device unlock didn't complete. Try again or enter your master password.", comment: "Unlock screen: inline message")
                return
            }
            do {
                let storedPassword = try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)
                try vaultSession.unlock(password: storedPassword)
                password = ""
                errorMessage = nil
                lastDeviceUnlockTimestamp = Date().timeIntervalSince1970
            } catch {
                errorMessage = String(localized: "Device unlock is unavailable. Enter your master password.", comment: "Unlock screen: inline message")
            }
        }
        return true
    }
}
