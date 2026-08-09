import Combine
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
    /// Phase-1 parse results, held between `passkeyCreate`/`passkeyGet` and the user's
    /// confirm click. Deliberately in memory only: a ceremony that does not survive an
    /// app restart is a ceremony that fails closed.
    private var pendingPasskeyCreates: [Int: (context: PasskeyCreateContext, originUrl: String)] = [:]
    private var pendingPasskeyGets: [Int: (context: PasskeyGetContext, originUrl: String)] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Repeat `requestUnlock` calls inside this window are answered but produce no
    /// second window activation or Touch ID prompt.
    static let unlockRequestDebounceInterval: TimeInterval = 2
    /// Fired for `.proposeSaveLogin` requests. Wired to real window-activation +
    /// pre-filled create-entry UI in Task 13 (`MyPassApp.init()` sets this to a
    /// closure that populates `NavigationState.pendingSaveProposal` and brings
    /// `MyPass.app` to the foreground) — not left as a bare extension point.
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    var onTotpSaveProposal: ((_ url: String, _ otpauthOrSecret: String, _ entryId: UUID?) -> Void)?
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
        // Locking the vault must invalidate anything mid-ceremony. Without this a
        // confirm arriving after a re-unlock would still find its phase-1 context and
        // write a passkey the user approved under a session that has since ended.
        vaultSession.$state
            .sink { [weak self] state in
                guard case .locked = state else { return }
                self?.pendingPasskeyCreates.removeAll()
                self?.pendingPasskeyGets.removeAll()
            }
            .store(in: &cancellables)
    }

    /// Entries carrying a passkey for `rpId`, with Recycle Bin residents excluded at the
    /// same choke point every other bridge request uses.
    private func passkeyEntries(forRelyingParty rpId: String, in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            .filter { $0.passkeyRelyingParty == rpId }
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
    }

    private func summary(for entry: KdbxEntry) -> ExtensionCredentialSummary {
        ExtensionCredentialSummary(
            id: entry.uuid.uuidString,
            title: entry.title,
            username: entry.login,
            hasTotp: entry.totpSecretBase32?.isEmpty == false,
            hasPasskey: entry.passkeyPrivateKeyPEM?.isEmpty == false
        )
    }

    /// Matches entries for `url`, then excludes any that live in the Recycle Bin —
    /// soft-deleted entries must never be surfaced to or filled by the extension.
    private func matchingEntries(forURL url: String, in database: KdbxDatabase) -> [KdbxEntry] {
        ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
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
            let matches = matchingEntries(forURL: url, in: database)
            return .credentialList(matches.map(summary(for:)))

        case .fillCredential(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = matchingEntries(forURL: url, in: database)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            // Only a live, time-boxed six-digit code crosses the bridge — the
            // Base32 seed itself is never sent to the extension.
            let liveTotp = entry.totpSecretBase32.flatMap {
                TOTPCode.currentCode(secretBase32: $0, digits: 6, period: 30, algorithm: .sha1, now: Date())
            }
            onCredentialFilled?(entry.uuid)
            vaultSession?.touchAccess(entryID: entry.uuid)
            return .credential(username: entry.login, password: entry.password, totp: liveTotp)

        case .getTotp(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = matchingEntries(forURL: url, in: database)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            guard let secret = entry.totpSecretBase32,
                  let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: Date()) else {
                return .error("entry has no TOTP secret")
            }
            // Deliberately no `onCredentialFilled?` / `vaultSession?.touchAccess` here:
            // fetching a live code for on-demand display is not a "fill" event.
            return .totp(code: code)

        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted

        case .proposeSaveTotp(_, let url, let otpauthOrSecret, let entryId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            var resolvedEntryID: UUID?
            if let entryId {
                guard let database = vaultSession?.currentDatabase else {
                    return .locked
                }
                let matches = matchingEntries(forURL: url, in: database)
                guard let entry = matches.first(where: { $0.uuid.uuidString == entryId }) else {
                    return .error("entry not found or domain mismatch")
                }
                resolvedEntryID = entry.uuid
            }
            onTotpSaveProposal?(url, otpauthOrSecret, resolvedEntryID)
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

        // The one request that runs past the locked gate (`isAnswerableWhileLocked`),
        // because reporting lock state is its entire job.
        case .getPasskeyProxyStatus(_, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            let unlocked = vaultSession?.currentDatabase != nil
            return .passkeyProxyStatus(unlocked: unlocked, paired: true, attachAllowed: unlocked)

        case .setPasskeyProxyEnabled(_, let enabled, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            UserDefaults.standard.set(enabled, forKey: "passkeyProxyEnabled")
            return .passkeyProxyEnabled(enabled: enabled)

        case .passkeyCreate(_, let requestId, let requestDetailsJson, let originUrl, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let context: PasskeyCreateContext
            do {
                context = try PasskeyCeremony.parseCreateRequest(requestDetailsJson)
            } catch PasskeyCeremonyError.unsupportedAlgorithm {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotSupportedError", message: "MyPass passkeys require ES256")
                )
            } catch {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Invalid passkey request")
                )
            }
            // Phase 1 parses and routes only — no key generation, no vault write.
            let matches = passkeyEntries(forRelyingParty: context.rpId, in: database)
            pendingPasskeyCreates[requestId] = (context: context, originUrl: originUrl)
            return .passkeyCreatePending(
                requestId: requestId, rpId: context.rpId, rpName: context.rpName,
                matches: matches.map(summary(for:))
            )

        case .passkeyCreateConfirm(_, let requestId, let entryId, let replace, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            guard let pending = pendingPasskeyCreates[requestId] else {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No pending request")
                )
            }
            let targetEntry = entryId.flatMap { id in
                EntrySearch.allEntries(in: database.rootGroup)
                    .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
                    .first(where: { $0.uuid.uuidString == id })
            }
            if entryId != nil, targetEntry == nil {
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Entry not found")
                )
            }
            if let targetEntry, targetEntry.passkeyPrivateKeyPEM?.isEmpty == false, !replace {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "InvalidStateError", message: "Entry already has a passkey")
                )
            }
            do {
                let result = try PasskeyCeremony.performCreate(context: pending.context, originUrl: pending.originUrl)
                let timestamp = now()
                var entry = targetEntry ?? {
                    var newEntry = KdbxEntry(
                        uuid: UUID(), iconID: 0, fields: [],
                        creationTime: timestamp, lastModificationTime: timestamp, lastAccessTime: timestamp,
                        locationChanged: timestamp, history: []
                    )
                    newEntry.title = pending.context.rpName.isEmpty ? pending.context.rpId : pending.context.rpName
                    newEntry.login = pending.context.userName
                    newEntry.url = pending.originUrl
                    return newEntry
                }()
                entry.passkeyRelyingParty = pending.context.rpId
                entry.passkeyCredentialId = result.credentialId
                entry.passkeyPrivateKeyPEM = result.privateKeyPEM
                entry.passkeyUserHandle = pending.context.userId
                entry.passkeyUsername = pending.context.userName
                entry.setPasskeyBackupFlags()
                entry.lastModificationTime = timestamp
                let isUpdate = targetEntry != nil
                vaultSession?.mutate { db in
                    if isUpdate, let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == entry.uuid }) {
                        db.rootGroup.entries[index] = entry
                    } else if !isUpdate {
                        db.rootGroup.entries.append(entry)
                    }
                }
                onCredentialFilled?(entry.uuid)
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(requestId: requestId, responseJson: result.responseJson, error: nil)
            } catch {
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Failed to create passkey")
                )
            }

        case .passkeyGet(_, let requestId, let requestDetailsJson, let originUrl, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let context: PasskeyGetContext
            do {
                context = try PasskeyCeremony.parseGetRequest(requestDetailsJson)
            } catch {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Invalid passkey request")
                )
            }
            let candidates = passkeyEntries(forRelyingParty: context.rpId, in: database)
                .filter { $0.passkeyPrivateKeyPEM?.isEmpty == false }
            let matched = context.allowCredentialIds.isEmpty
                ? candidates
                : candidates.filter { entry in
                    guard let credentialId = entry.passkeyCredentialId else { return false }
                    return context.allowCredentialIds.contains(credentialId)
                }
            guard !matched.isEmpty else {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No passkey for this site")
                )
            }
            pendingPasskeyGets[requestId] = (context: context, originUrl: originUrl)
            return .passkeyGetPending(requestId: requestId, rpId: context.rpId, matches: matched.map(summary(for:)))

        case .passkeyGetApprove(_, let requestId, let entryId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            guard let pending = pendingPasskeyGets[requestId] else {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No pending request")
                )
            }
            // Re-resolved against the relying party the ceremony actually asked for, so a
            // compromised extension cannot name an entry belonging to another site.
            guard let entry = passkeyEntries(forRelyingParty: pending.context.rpId, in: database)
                    .first(where: { $0.uuid.uuidString == entryId }),
                  let pem = entry.passkeyPrivateKeyPEM,
                  let credentialId = entry.passkeyCredentialId else {
                pendingPasskeyGets.removeValue(forKey: requestId)
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Passkey entry not found")
                )
            }
            do {
                let result = try PasskeyCeremony.performGet(
                    context: pending.context, originUrl: pending.originUrl,
                    privateKeyPEM: pem, credentialId: credentialId, userHandle: entry.passkeyUserHandle
                )
                pendingPasskeyGets.removeValue(forKey: requestId)
                vaultSession?.touchAccess(entryID: entry.uuid)
                return .passkeyGetComplete(requestId: requestId, responseJson: result.responseJson, error: nil)
            } catch {
                pendingPasskeyGets.removeValue(forKey: requestId)
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Failed to sign assertion")
                )
            }

        case .passkeyCancel(_, let requestId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            pendingPasskeyCreates.removeValue(forKey: requestId)
            pendingPasskeyGets.removeValue(forKey: requestId)
            return .passkeyCancelled(requestId: requestId)
        }
    }
}
