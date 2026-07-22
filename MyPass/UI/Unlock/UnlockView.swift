import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("MyPass")
                .font(.largeTitle)
            SecureField("Мастер-пароль", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(attemptUnlock)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Разблокировать", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Неверный пароль или повреждённый файл."
        }
    }
}
