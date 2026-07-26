import SwiftUI

struct MenuBarUnlockPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @State private var password = ""
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)

            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
                    .buttonStyle(.bordered)
            }

            Text("The vault remains locked until you unlock it manually.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 280)
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
        // Same contract as UnlockView — retrieve succeeds after Touch ID;
        // full derived-key unlock wiring follows existing UnlockView path.
        if (try? biometricKeyStore.retrieve(account: "master")) == nil {
            errorMessage = "Touch ID is unavailable."
        } else {
            errorMessage = nil
        }
    }
}
