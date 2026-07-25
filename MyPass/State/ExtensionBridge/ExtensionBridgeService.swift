import Foundation
import MyPassKit
import ExtensionBridgeKit

/// UI-agnostic request handler for the browser-extension bridge. Token
/// validation happens one layer up, in `LoopbackServer` (Фаза 4, Task 6),
/// before a request ever reaches this type — `handle(_:)` trusts its caller.
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    /// Fired for `.proposeSaveLogin` requests. Wired to real window-activation +
    /// pre-filled create-entry UI in Task 13 (`MyPassApp.init()` sets this to a
    /// closure that populates `NavigationState.pendingSaveProposal` and brings
    /// `MyPass.app` to the foreground) — not left as a bare extension point.
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?

    init(vaultSession: VaultSession) {
        self.vaultSession = vaultSession
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        switch request {
        case .getCredentials(_, let url):
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            let summaries = matches.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login)
            }
            return .credentialList(summaries)

        case .fillCredential(_, let id, let url):
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            return .credential(username: entry.login, password: entry.password, totp: entry.totpSecretBase32)

        case .proposeSaveLogin(_, let url, let username, let password):
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted
        }
    }
}
