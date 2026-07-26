import SwiftUI
import MyPassKit

struct SecuritySettingsPane: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var touchIDEnabled = false
    @State private var touchIDError: String?
    @State private var confirmPassword = ""
    @State private var showConfirmSheet = false

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                if newValue {
                    enableTouchID()
                } else {
                    disableTouchID()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Stepper("Lock automatically after inactivity: \(Int(autoLockTimeoutMinutes)) min",
                        value: $autoLockTimeoutMinutes, in: 1...120)
                SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
            } header: {
                Text("Auto-Lock")
            }

            Section {
                Toggle("Unlock with Touch ID", isOn: touchIDBinding)
                SettingsHelperText(text: "Use Touch ID to unlock without typing your master password; after restart, master password is still required per security model.")
                if let touchIDError {
                    Text(touchIDError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Touch ID")
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
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshTouchIDState()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .sheet(isPresented: $showConfirmSheet) {
            touchIDConfirmSheet
        }
    }

    private var touchIDConfirmSheet: some View {
        VStack(spacing: 16) {
            Text("Confirm Master Password")
                .font(.headline)

            Text("Enter your master password to enroll Touch ID for this vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Master Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(confirmTouchIDEnrollment)

            HStack {
                Button("Cancel") {
                    confirmPassword = ""
                    showConfirmSheet = false
                    touchIDEnabled = VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore)
                }
                Spacer()
                Button("Enroll") {
                    confirmTouchIDEnrollment()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func refreshTouchIDState() {
        touchIDEnabled = VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore)
    }

    private func enableTouchID() {
        touchIDError = nil
        guard vaultSession.currentDatabase != nil else {
            touchIDError = "Unlock the vault before enabling Touch ID."
            touchIDEnabled = false
            return
        }
        showConfirmSheet = true
    }

    private func disableTouchID() {
        touchIDError = nil
        do {
            try VaultBiometricEnrollment.remove(biometricKeyStore: biometricKeyStore)
            touchIDEnabled = false
        } catch {
            touchIDError = "Could not remove Touch ID enrollment."
            touchIDEnabled = true
        }
    }

    private func confirmTouchIDEnrollment() {
        touchIDError = nil
        do {
            guard vaultSession.currentDatabase != nil else {
                throw VaultSessionError.notUnlocked
            }
            guard let vaultData = try vaultSession.loadVaultData() else {
                touchIDError = "No vault data found."
                touchIDEnabled = false
                confirmPassword = ""
                showConfirmSheet = false
                return
            }
            try VaultBiometricEnrollment.enroll(
                password: confirmPassword,
                vaultData: vaultData,
                biometricKeyStore: biometricKeyStore
            )
            touchIDEnabled = true
            confirmPassword = ""
            showConfirmSheet = false
        } catch let error as KdbxDatabaseError where error == .wrongPassword {
            touchIDError = "Incorrect master password."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        } catch is VaultSessionError {
            touchIDError = "Unlock the vault before enabling Touch ID."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        } catch {
            touchIDError = "Touch ID enrollment failed."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        }
    }
}
