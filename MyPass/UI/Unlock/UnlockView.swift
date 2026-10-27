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
    @State private var openExistingVaultURL: URL?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var deviceUnlockButtonLabel: String {
        switch (touchIDEnabled, macPasswordEnabled) {
        case (true, true): return "Unlock with Touch ID or Password"
        case (true, false): return "Touch ID"
        case (false, true): return "Unlock with Mac Password"
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
                .onSubmit(attemptUnlock)

            KeyboardLayoutIndicator()

            if let errorMessage {
                Text(errorMessage)
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

            Button("Open Existing .kdbx…") { openExistingVault() }
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
            // Appearing never prompts by itself. The one exception is an explicit
            // extension Unlock that arrived while the window was closed, before this
            // view existed — `MyPassApp.onUnlockRequested` recorded it on the
            // coordinator and the notification below was dropped for lack of an observer.
            if !isFirstRun, canShowDeviceUnlockButton,
               deviceUnlockPromptCoordinator.consumeExtensionUnlockRequest() {
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
        .sheet(isPresented: Binding(
            get: { openExistingVaultURL != nil },
            set: { if !$0 { openExistingVaultURL = nil } }
        )) {
            if let url = openExistingVaultURL {
                OpenExistingVaultSheet(
                    fileURL: url,
                    onSuccess: { database, openedPassword in
                        openExistingVaultURL = nil
                        completeOpenExistingVault(fileURL: url, password: openedPassword, database: database)
                    },
                    onCancel: { openExistingVaultURL = nil }
                )
            }
        }
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
            errorMessage = "Incorrect password or corrupted file."
        }
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openExistingVaultURL = url
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
            errorMessage = "Could not switch to this vault file."
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
            errorMessage = "Device unlock is unavailable. Enter your master password."
            return false
        }
        guard let accessControl = DeviceUnlockAccessControl.forToggles(
            touchIDEnabled: touchIDEnabled,
            macPasswordEnabled: macPasswordEnabled
        ) else {
            deviceUnlockPromptCoordinator.promptFinished()
            errorMessage = "Device unlock is unavailable. Enter your master password."
            return false
        }
        DeviceUnlockAuthenticator.authenticate(accessControl: accessControl) { success in
            defer { deviceUnlockPromptCoordinator.promptFinished() }
            guard success else {
                // The attempt was deliberate, so a cancelled or failed Touch ID gets
                // feedback instead of silently doing nothing.
                errorMessage = "Device unlock didn't complete. Try again or enter your master password."
                return
            }
            do {
                let storedPassword = try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)
                try vaultSession.unlock(password: storedPassword)
                password = ""
                errorMessage = nil
                lastDeviceUnlockTimestamp = Date().timeIntervalSince1970
            } catch {
                errorMessage = "Device unlock is unavailable. Enter your master password."
            }
        }
        return true
    }
}
