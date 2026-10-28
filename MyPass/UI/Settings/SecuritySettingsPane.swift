import SwiftUI
import MyPassKit

struct SecuritySettingsPane: View {
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lockOnDeviceSleepEnabled") private var lockOnDeviceSleepEnabled = true
    @AppStorage("autoLockIdleTimeout") private var autoLockIdleTimeout: AutoLockIdleTimeout = .thirtyMinutes
    @AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
    @AppStorage("lastDeviceUnlockTimestamp") private var lastDeviceUnlockTimestamp: Double = 0
    @AppStorage("lastFullPasswordEntryTimestamp") private var lastFullPasswordEntryTimestamp: Double = 0
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var unlockError: String?
    @State private var confirmPassword = ""
    @State private var showConfirmSheet = false
    @State private var pendingAccessControl: DeviceUnlockAccessControl?
    @State private var priorTouchIDEnabled = false
    @State private var priorMacPasswordEnabled = false

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                priorTouchIDEnabled = touchIDEnabled
                priorMacPasswordEnabled = macPasswordEnabled
                touchIDEnabled = newValue
                updateDeviceUnlockEnrollment()
            }
        )
    }

    private var macPasswordBinding: Binding<Bool> {
        Binding(
            get: { macPasswordEnabled },
            set: { newValue in
                priorTouchIDEnabled = touchIDEnabled
                priorMacPasswordEnabled = macPasswordEnabled
                macPasswordEnabled = newValue
                updateDeviceUnlockEnrollment()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Unlock using Touch ID", isOn: touchIDBinding)
                Toggle("Unlock app with Mac password", isOn: macPasswordBinding)

                Picker("Unlock with device:", selection: $unlockWithDeviceWindow) {
                    ForEach(UnlockDeviceWindow.allCases) { window in
                        Text(window.pickerLabel).tag(window)
                    }
                }

                Picker("Require account password:", selection: $requireAccountPasswordWindow) {
                    ForEach(RequirePasswordWindow.allCases) { window in
                        Text(window.pickerLabel).tag(window)
                    }
                }

                SettingsHelperText(text: "Unlock without typing your master password using Touch ID or your Mac password. You'll still be asked for the master password on the schedule above.")

                if let unlockError {
                    // Already localized where it is set, so it is shown as is.
                    Text(verbatim: unlockError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Unlock")
            }

            Section {
                Toggle("Lock when device locks or sleeps", isOn: $lockOnDeviceSleepEnabled)
                Picker("Lock after the device is idle for:", selection: $autoLockIdleTimeout) {
                    ForEach(AutoLockIdleTimeout.allCases) { timeout in
                        Text(timeout.pickerLabel).tag(timeout)
                    }
                }
                SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
            } header: {
                Text("Auto-lock")
            }

            Section {
                Stepper("Clear clipboard after: \(clipboardClearSeconds) s",
                        value: $clipboardClearSeconds, in: 10...120, step: 5)
                SettingsHelperText(text: "Usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.")
            } header: {
                Text("Clipboard")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoLockController.timeout = autoLockIdleTimeout.seconds
            autoLockController.lockOnSleepEnabled = lockOnDeviceSleepEnabled
            // Reconcile the toggle display against real Keychain state: if the item
            // disappeared out from under the app (biometry invalidated, Keychain
            // reset, migrated to a new Mac), don't keep claiming device unlock is on.
            // `isEnrolled` uses `hasStoredKey`, which is attributes-only and does not
            // trigger an auth prompt, so this is safe and cheap on every appear.
            if !DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore),
               touchIDEnabled || macPasswordEnabled {
                touchIDEnabled = false
                macPasswordEnabled = false
            }
        }
        .onChange(of: autoLockIdleTimeout) { _, newValue in
            autoLockController.timeout = newValue.seconds
        }
        .onChange(of: lockOnDeviceSleepEnabled) { _, newValue in
            autoLockController.lockOnSleepEnabled = newValue
        }
        .sheet(isPresented: $showConfirmSheet) {
            confirmSheet
        }
    }

    private var confirmSheet: some View {
        VStack(spacing: 16) {
            Text("Confirm Master Password")
                .font(.headline)

            Text("Enter your master password to enable device unlock for this vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Master Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(confirmEnrollment)

            KeyboardLayoutIndicator()

            HStack {
                Button("Cancel", action: cancelEnrollment)
                Spacer()
                Button("Enable", action: confirmEnrollment)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func updateDeviceUnlockEnrollment() {
        unlockError = nil
        guard let accessControl = DeviceUnlockAccessControl.forToggles(
            touchIDEnabled: touchIDEnabled,
            macPasswordEnabled: macPasswordEnabled
        ) else {
            try? DeviceUnlockEnrollment.remove(biometricKeyStore: biometricKeyStore)
            return
        }

        if let existingPassword = try? DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore) {
            do {
                try DeviceUnlockEnrollment.enroll(
                    password: existingPassword,
                    accessControl: accessControl,
                    biometricKeyStore: biometricKeyStore
                )
            } catch {
                // `DeviceUnlockEnrollment.enroll` deletes the old Keychain item before
                // storing the new one (see `BiometricKeyStore.store`), so if this throws,
                // the old item may already be gone even though nothing has been restored
                // yet. Restoring the toggle display to the pre-edit values and NOT calling
                // `remove()` again is still the safest behavior here — there may be
                // nothing left to remove.
                unlockError = String(localized: "Could not update device unlock settings.", comment: "Security settings: device unlock error")
                touchIDEnabled = priorTouchIDEnabled
                macPasswordEnabled = priorMacPasswordEnabled
            }
            return
        }

        guard vaultSession.currentDatabase != nil else {
            unlockError = String(localized: "Unlock the vault before enabling device unlock.", comment: "Security settings: device unlock error")
            restoreToggles()
            return
        }
        pendingAccessControl = accessControl
        showConfirmSheet = true
    }

    private func cancelEnrollment() {
        confirmPassword = ""
        showConfirmSheet = false
        pendingAccessControl = nil
        restoreToggles()
    }

    /// Restores the toggles to their values from before the in-progress edit, and —
    /// only when the restored state is genuinely "both off" — ensures the Keychain
    /// item is actually removed, so the Settings display never claims device unlock is
    /// off while a working enrollment item is still reachable from UnlockView /
    /// MenuBarUnlockPanelView.
    private func restoreToggles() {
        touchIDEnabled = priorTouchIDEnabled
        macPasswordEnabled = priorMacPasswordEnabled
        if !priorTouchIDEnabled && !priorMacPasswordEnabled {
            try? DeviceUnlockEnrollment.remove(biometricKeyStore: biometricKeyStore)
        }
    }

    private func confirmEnrollment() {
        unlockError = nil
        guard let accessControl = pendingAccessControl else {
            showConfirmSheet = false
            return
        }
        do {
            guard let vaultData = try vaultSession.loadVaultData() else {
                unlockError = String(localized: "No vault data found.", comment: "Security settings: device unlock error")
                cancelEnrollment()
                return
            }
            _ = try KdbxDatabase.open(data: vaultData, password: confirmPassword)
            try DeviceUnlockEnrollment.enroll(
                password: confirmPassword,
                accessControl: accessControl,
                biometricKeyStore: biometricKeyStore
            )
            // The KdbxDatabase.open(data:password:) verification above is a full,
            // real password-entry event, semantically identical to UnlockView's
            // manual unlock — record it so a device-unlock button is immediately
            // available on the next lock instead of being hidden by a stale window.
            let now = Date().timeIntervalSince1970
            lastDeviceUnlockTimestamp = now
            lastFullPasswordEntryTimestamp = now
            confirmPassword = ""
            showConfirmSheet = false
            pendingAccessControl = nil
        } catch let error as KdbxDatabaseError where error == .wrongPassword {
            unlockError = String(localized: "Incorrect master password.", comment: "Security settings: device unlock error")
            cancelEnrollment()
        } catch {
            unlockError = String(localized: "Could not enable device unlock.", comment: "Security settings: device unlock error")
            cancelEnrollment()
        }
    }
}
