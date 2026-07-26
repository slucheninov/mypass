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
        VStack(spacing: 16) {
            Text("MyPass")
                .font(.largeTitle)
            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(attemptUnlock)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
            }
        }
        .padding(40)
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
