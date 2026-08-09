import SwiftUI
import MyPassKit

/// The full contents of a passkey, shown on demand from both the entry card and the
/// editor. Everything here is diagnostic — the relying party the credential is bound to
/// and its credential ID — which is why it lives behind a Show button rather than on the
/// card itself. The private key is deliberately absent: it has no reason to be readable
/// anywhere in the UI.
struct PasskeyDetailsPopover: View {
    let entry: KdbxEntry
    /// Points at wherever removal lives, for the surface that does not offer it.
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Passkey")
                .font(.headline)
            if let rpId = entry.passkeyRelyingParty {
                detailLine(label: "Site", value: rpId)
            }
            if let username = entry.passkeyUsername, !username.isEmpty {
                detailLine(label: "Username", value: username)
            }
            if let created = entry.passkeyCreatedAt {
                detailLine(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened))
            } else {
                // A passkey imported from KeePassXC carries no creation date. Say so,
                // rather than leaving a gap the user has to interpret.
                detailLine(label: "Created", value: "Unknown — created outside MyPass")
            }
            if let credentialId = entry.passkeyCredentialId {
                detailLine(label: "Credential ID", value: PasskeyBase64URL.encode(credentialId))
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func detailLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
