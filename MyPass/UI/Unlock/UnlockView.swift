import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @State private var password: String = ""
    @State private var errorMessage: String?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var hasStoredBiometricKey: Bool {
        (try? biometricKeyStore.retrieve(account: "master")) != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MyPass")
                .font(.system(size: 28, weight: .semibold))

            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

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

            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
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
        } catch {
            errorMessage = "Incorrect password or corrupted file."
        }
    }

    private func attemptBiometricUnlock() {
        // Placeholder wiring for this task: retrieving the stored derived key succeeds
        // only after Touch ID biometric confirmation (enforced by SecAccessControl on the
        // Keychain item itself, not by this view). Mapping the derived key back into an
        // unlock call is deferred — this button demonstrates the store/retrieve contract end to end.
        errorMessage = (try? biometricKeyStore.retrieve(account: "master")) == nil
            ? "Touch ID is unavailable."
            : nil
    }
}
