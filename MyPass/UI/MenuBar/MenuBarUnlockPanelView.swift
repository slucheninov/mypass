import SwiftUI

struct MenuBarUnlockPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var deviceUnlockPromptCoordinator: DeviceUnlockPromptCoordinator
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lastDeviceUnlockTimestamp") private var lastDeviceUnlockTimestamp: Double = 0
    @AppStorage("lastFullPasswordEntryTimestamp") private var lastFullPasswordEntryTimestamp: Double = 0

    @State private var password = ""
    @State private var errorMessage: String?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
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
        VStack(spacing: 16) {
            Text("MyPass is locked")
                .font(.headline)

            Image("BrandKey")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            SecureField("Enter Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attemptUnlock)

            KeyboardLayoutIndicator()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)

            if canShowDeviceUnlockButton {
                Button("Unlock with Device", systemImage: "touchid") {
                    attemptDeviceUnlock(trigger: .explicit)
                }
                    .buttonStyle(.bordered)
            }

            Text("The vault remains locked until you unlock it manually.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 280)
        .onAppear {
            if canShowDeviceUnlockButton {
                attemptDeviceUnlock(trigger: .automatic)
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

    /// Mirrors `UnlockView.attemptDeviceUnlock(trigger:)` — see its doc comment for
    /// why `trigger` gates both the coordinator and the failure-feedback behavior.
    @discardableResult
    private func attemptDeviceUnlock(trigger: DeviceUnlockPromptTrigger) -> Bool {
        let allowed = trigger == .automatic
            ? deviceUnlockPromptCoordinator.requestAutoPrompt()
            : deviceUnlockPromptCoordinator.requestExplicitPrompt()
        guard allowed else { return false }

        guard canShowDeviceUnlockButton else {
            deviceUnlockPromptCoordinator.promptFinished()
            if trigger == .explicit {
                errorMessage = "Device unlock is unavailable. Enter your master password."
            }
            return false
        }
        guard let accessControl = DeviceUnlockAccessControl.forToggles(
            touchIDEnabled: touchIDEnabled,
            macPasswordEnabled: macPasswordEnabled
        ) else {
            deviceUnlockPromptCoordinator.promptFinished()
            if trigger == .explicit {
                errorMessage = "Device unlock is unavailable. Enter your master password."
            }
            return false
        }
        DeviceUnlockAuthenticator.authenticate(accessControl: accessControl) { success in
            defer { deviceUnlockPromptCoordinator.promptFinished() }
            guard success else {
                if trigger == .explicit {
                    errorMessage = "Device unlock didn't complete. Try again or enter your master password."
                }
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
