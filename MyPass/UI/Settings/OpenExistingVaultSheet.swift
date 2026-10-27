import SwiftUI
import MyPassKit

/// Prompts for the master password of an existing `.kdbx` file the user just
/// picked via `NSOpenPanel` (`EntryListView.openExistingVault()`, or the same
/// flow from `UnlockView` while locked), and opens it before handing control
/// back to the caller — so a wrong password surfaces as an inline error right
/// here rather than as a generic failure once `VaultSession.retargetToOpenExistingVault`
/// runs.
struct OpenExistingVaultSheet: View {
    let fileURL: URL
    let onSuccess: (KdbxDatabase, String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Existing Vault")
                .font(.headline)
            Text(verbatim: fileURL.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attemptOpen)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Open") { attemptOpen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func attemptOpen() {
        guard !password.isEmpty else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let database = try KdbxDatabase.open(data: data, password: password)
            onSuccess(database, password)
            dismiss()
        } catch {
            errorMessage = String(localized: "Incorrect password, or this file isn't a valid .kdbx vault MyPass can open.", comment: "Open existing vault sheet: inline error")
        }
    }
}
