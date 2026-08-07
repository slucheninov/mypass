import Foundation
import MyPassKit
import ExtensionBridgeKit

/// UI-agnostic request handler for the browser-extension bridge. Token
/// validation happens one layer up, in `LoopbackServer` (Phase 4, Task 6),
/// before a request ever reaches this type — `handle(_:)` trusts its caller.
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    private let pairingManager: ExtensionPairingManager
    /// Injectable so the debounce is testable without sleeping.
    private let now: () -> Date
    private var lastAcceptedUnlockRequestAt: Date?

    /// Repeat `requestUnlock` calls inside this window are answered but produce no
    /// second window activation or Touch ID prompt.
    static let unlockRequestDebounceInterval: TimeInterval = 2
    /// Fired for `.proposeSaveLogin` requests. Wired to real window-activation +
    /// pre-filled create-entry UI in Task 13 (`MyPassApp.init()` sets this to a
    /// closure that populates `NavigationState.pendingSaveProposal` and brings
    /// `MyPass.app` to the foreground) — not left as a bare extension point.
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    var onCredentialFilled: ((UUID) -> Void)?
    /// Fired for `.requestUnlock`. Wired in `MyPassApp.init()` to bring the window
    /// forward and re-trigger the Touch ID prompt. The service itself never unlocks
    /// anything — presenting the unlock UI is the app layer's job.
    var onUnlockRequested: (() -> Void)?

    init(
        vaultSession: VaultSession,
        pairingManager: ExtensionPairingManager,
        now: @escaping () -> Date = Date.init
    ) {
        self.vaultSession = vaultSession
        self.pairingManager = pairingManager
        self.now = now
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        guard vaultSession?.currentDatabase != nil || request.isAnswerableWhileLocked else {
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

        case .requestUnlock(_, let pairing):
            // Order is load-bearing — see the design spec's "Order of checks".
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            // Checked before the debounce so a click arriving just after a successful
            // unlock always tells the popup to re-query rather than being swallowed.
            guard vaultSession?.currentDatabase == nil else {
                return .unlockNotNeeded
            }
            let timestamp = now()
            if let last = lastAcceptedUnlockRequestAt,
               timestamp.timeIntervalSince(last) < Self.unlockRequestDebounceInterval {
                return .unlockPresented
            }
            lastAcceptedUnlockRequestAt = timestamp
            onUnlockRequested?()
            return .unlockPresented
        }
    }
}
