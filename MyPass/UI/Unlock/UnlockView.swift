import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lastDeviceUnlockTimestamp") private var lastDeviceUnlockTimestamp: Double = 0
    @AppStorage("lastFullPasswordEntryTimestamp") private var lastFullPasswordEntryTimestamp: Double = 0

    @State private var password: String = ""
    @State private var errorMessage: String?

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

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(attemptUnlock)

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
                Button(deviceUnlockButtonLabel, systemImage: deviceUnlockButtonSymbol, action: attemptDeviceUnlock)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 320)
            }

            Text("Vault is locked. Enter your master password or use Touch ID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func attemptDeviceUnlock() {
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
}
