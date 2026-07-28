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
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var unlockError: String?
    @State private var confirmPassword = ""
    @State private var showConfirmSheet = false
    @State private var pendingAccessControl: DeviceUnlockAccessControl?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                touchIDEnabled = newValue
                updateDeviceUnlockEnrollment()
            }
        )
    }

    private var macPasswordBinding: Binding<Bool> {
        Binding(
            get: { macPasswordEnabled },
            set: { newValue in
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
                    Text(unlockError)
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
                unlockError = "Could not update device unlock settings."
                touchIDEnabled = false
                macPasswordEnabled = false
            }
            return
        }

        guard vaultSession.currentDatabase != nil else {
            unlockError = "Unlock the vault before enabling device unlock."
            touchIDEnabled = false
            macPasswordEnabled = false
            return
        }
        pendingAccessControl = accessControl
        showConfirmSheet = true
    }

    private func cancelEnrollment() {
        confirmPassword = ""
        showConfirmSheet = false
        pendingAccessControl = nil
        touchIDEnabled = false
        macPasswordEnabled = false
    }

    private func confirmEnrollment() {
        unlockError = nil
        guard let accessControl = pendingAccessControl else {
            showConfirmSheet = false
            return
        }
        do {
            guard let vaultData = try vaultSession.loadVaultData() else {
                unlockError = "No vault data found."
                cancelEnrollment()
                return
            }
            _ = try KdbxDatabase.open(data: vaultData, password: confirmPassword)
            try DeviceUnlockEnrollment.enroll(
                password: confirmPassword,
                accessControl: accessControl,
                biometricKeyStore: biometricKeyStore
            )
            confirmPassword = ""
            showConfirmSheet = false
            pendingAccessControl = nil
        } catch let error as KdbxDatabaseError where error == .wrongPassword {
            unlockError = "Incorrect master password."
            cancelEnrollment()
        } catch {
            unlockError = "Could not enable device unlock."
            cancelEnrollment()
        }
    }
}
