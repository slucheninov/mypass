import Foundation
import MyPassKit
import ExtensionBridgeKit

/// UI-agnostic request handler for the browser-extension bridge. Token
/// validation happens one layer up, in `LoopbackServer` (Phase 4, Task 6),
/// before a request ever reaches this type — `handle(_:)` trusts its caller.
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    private let pairingManager: ExtensionPairingManager
    /// Fired for `.proposeSaveLogin` requests. Wired to real window-activation +
    /// pre-filled create-entry UI in Task 13 (`MyPassApp.init()` sets this to a
    /// closure that populates `NavigationState.pendingSaveProposal` and brings
    /// `MyPass.app` to the foreground) — not left as a bare extension point.
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    var onCredentialFilled: ((UUID) -> Void)?

    init(vaultSession: VaultSession, pairingManager: ExtensionPairingManager) {
        self.vaultSession = vaultSession
        self.pairingManager = pairingManager
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        guard vaultSession?.currentDatabase != nil else {
            return .locked
        }
        switch request {
        case .startPairing(_, let browser):
            _ = pairingManager.startPairing(browser: browser)
            return .pairingStarted
        case .completePairing(_, let code):
            if let secret = pairingManager.completePairing(code: code) {
                return .paired(secret: secret)
            }
            return .error("invalid_code")
        case .getCredentials(_, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            let summaries = matches.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login)
            }
            return .credentialList(summaries)

        case .fillCredential(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            // TOTP filling isn't implemented anywhere downstream (no consumer
            // reads `.credential`'s totp field), so the raw base32 seed is
            // never populated here — sending a long-lived secret into a web
            // page's content-script world for a feature that doesn't exist
            // would be a pure liability. Always `nil` until TOTP-filling is
            // actually built.
            onCredentialFilled?(entry.uuid)
            vaultSession?.touchAccess(entryID: entry.uuid)
            return .credential(username: entry.login, password: entry.password, totp: nil)

        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted
        }
    }
}
