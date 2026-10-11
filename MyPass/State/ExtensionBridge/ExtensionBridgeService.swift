import Combine
import Foundation
import MyPassKit
import ExtensionBridgeKit

/// Notified when a bridge request represents deliberate user activity, so the idle
/// auto-lock timer can be reset the same way it is for in-app key/mouse events.
/// `AutoLockController.recordActivity()` already matches this shape.
protocol AutoLockActivityRecording: AnyObject {
    func recordActivity()
}

/// UI-agnostic request handler for the browser-extension bridge. Token
/// validation happens one layer up, in `LoopbackServer` (Phase 4, Task 6),
/// before a request ever reaches this type — `handle(_:)` trusts its caller.
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    private let pairingManager: ExtensionPairingManager
    private let browserDiagnostics: BrowserDiagnosticsStore
    /// Injectable so the debounce is testable without sleeping.
    private let now: () -> Date
    /// Weak, like `vaultSession` — the service observes the auto-lock controller's
    /// lifecycle, it does not own it. `nil` in contexts that don't wire one up (most
    /// existing tests), which simply means bridge traffic never resets any timer.
    private weak var autoLockActivityRecorder: AutoLockActivityRecording?
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
    var onBrowserSettingsRequested: (() -> Void)?

    init(
        vaultSession: VaultSession,
        pairingManager: ExtensionPairingManager,
        now: @escaping () -> Date = Date.init,
        autoLockActivityRecorder: AutoLockActivityRecording? = nil,
        browserDiagnostics: BrowserDiagnosticsStore = .shared
    ) {
        self.vaultSession = vaultSession
        self.pairingManager = pairingManager
        self.browserDiagnostics = browserDiagnostics
        self.now = now
        self.autoLockActivityRecorder = autoLockActivityRecorder
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
    /// same choke point every other bridge request uses. This lookup is by relying-party
    /// id, not by URL, so it never runs through `ExtensionEntryMatcher` — which means a
    /// never-mode entry's exclusion has to be enforced here explicitly, or an entry the
    /// user told "do not offer this to the browser" would still surface its passkey to
    /// both the create and the get flow (both of which call this function, directly or
    /// indirectly through `passkeyCreateCandidates(forOriginUrl:rpId:in:)`).
    private func passkeyEntries(forRelyingParty rpId: String, in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            .filter { $0.passkeyRelyingParty == rpId }
            .filter { $0.uriMatchMode != .never }
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
    }

    private func summary(for entry: KdbxEntry) -> ExtensionCredentialSummary {
        ExtensionCredentialSummary(
            id: entry.uuid.uuidString,
            title: entry.title,
            username: entry.login,
            hasTotp: entry.totpSecretBase32?.isEmpty == false,
            hasPasskey: entry.hasPasskey
        )
    }

    /// Same fields as `summary(for:)`, plus the saved URL and entry type so a
    /// browsed row can open its site. An empty URL stays nil and is omitted on the wire.
    private func browseSummary(for entry: KdbxEntry) -> ExtensionCredentialSummary {
        ExtensionCredentialSummary(
            id: entry.uuid.uuidString,
            title: entry.title,
            username: entry.entryType == .address ? entry.address.fullName : entry.login,
            hasTotp: entry.totpSecretBase32?.isEmpty == false,
            hasPasskey: entry.hasPasskey,
            url: entry.url.isEmpty ? nil : entry.url,
            entryType: entry.entryType.rawValue
        )
    }

    /// Favorites the popup shows when the active tab is not a website. Recycle Bin
    /// residents stay hidden, and a never-mode entry stays hidden too: the user told
    /// the app not to offer it to the browser.
    private func favoriteEntries(in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            .filter { $0.isFavorite }
            .filter { $0.uriMatchMode != .never }
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Popup category menu. Nil means the category name is not one the popup offers.
    /// Favorites keeps the never-mode exclusion. The other categories are the vault
    /// browser, so a never-mode entry still appears there.
    private func browseEntries(category: String, in database: KdbxDatabase) -> [KdbxEntry]? {
        if category == "favorites" {
            return favoriteEntries(in: database)
        }
        let live = EntrySearch.allEntries(in: database.rootGroup)
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        let matched: [KdbxEntry]
        switch category {
        case "all":
            matched = live
        case "logins":
            matched = live.filter { $0.entryType == .login }
        case "codes":
            matched = live.filter { $0.totpSecretBase32?.isEmpty == false }
        case "passkeys":
            matched = live.filter { $0.hasPasskey }
        case "addresses":
            matched = live.filter { $0.entryType == .address }
        case "cards":
            matched = live.filter { $0.entryType == .card }
        case "notes":
            matched = live.filter { $0.entryType == .notes }
        default:
            return nil
        }
        return matched.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func makeCreatedEntry(
        entryType: EntryType,
        title: String,
        username: String,
        password: String,
        url: String,
        cardNumber: String,
        cardholderName: String,
        expiry: String,
        cvv: String,
        notes: String,
        favorite: Bool,
        match: String,
        otp: String
    ) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = title
        entry.entryType = entryType
        entry.isFavorite = favorite
        switch entryType {
        case .login:
            entry.login = username
            entry.password = password
            entry.url = url
            entry.notes = notes
            if let mode = URIMatchMode(rawValue: match) {
                entry.uriMatchMode = mode
            }
            EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: otp)
        case .address:
            break // Address creation uses the dedicated native editor, not the flat login/card payload.
        case .card:
            entry.cardholderName = cardholderName
            entry.cardNumber = cardNumber.filter(\.isNumber)
            entry.expiryDate = expiry
            entry.cvv = cvv
            entry.login = cardholderName
        case .notes:
            entry.notesBody = notes
        }
        return entry
    }

    /// Matches entries for `url`, then excludes any that live in the Recycle Bin —
    /// soft-deleted entries must never be surfaced to or filled by the extension.
    private func matchingEntries(forURL url: String, in database: KdbxDatabase) -> [KdbxEntry] {
        ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            .filter { $0.entryType != .address }
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
    }

    /// Candidate entries for a `passkeyCreate` prompt: the union of entries whose saved
    /// URL domain-matches the page origin (so a plain Login the user already has for the
    /// site is offered as the save target) and entries that already carry a passkey for
    /// `rpId` (so "replace passkey" is reachable even if the entry's own URL doesn't PSL-
    /// match the current origin, e.g. it was saved from a different subdomain). Domain
    /// matches are listed first; passkey-only entries are appended without duplicating any
    /// entry that satisfied both. This differs deliberately from `.passkeyGet`, where only
    /// entries that already hold a passkey for the rpId are ever candidates — signing in
    /// must never offer to "create" against a plain Login that has no key to assert with.
    private func passkeyCreateCandidates(forOriginUrl originUrl: String, rpId: String, in database: KdbxDatabase) -> [KdbxEntry] {
        let domainMatches = matchingEntries(forURL: originUrl, in: database)
        let passkeyMatches = passkeyEntries(forRelyingParty: rpId, in: database)
        var seen = Set(domainMatches.map(\.uuid))
        var candidates = domainMatches
        for entry in passkeyMatches where !seen.contains(entry.uuid) {
            seen.insert(entry.uuid)
            candidates.append(entry)
        }
        return candidates
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        let response = response(for: request)
        // Recorded only once the response is known, and only if the request was both
        // gesture-gated (`resetsAutoLockTimer`) AND actually served — an unpaired,
        // locked, or refused request must not keep the vault awake just because it was
        // gesture-shaped. See `requestWasServed(_:)` below.
        if request.resetsAutoLockTimer, requestWasServed(response) {
            autoLockActivityRecorder?.recordActivity()
        }
        return response
    }

    /// Whether `response` represents the request actually being served, as opposed to
    /// being refused for a reason unrelated to anything the user did (not paired, vault
    /// locked, or an explicit error/refusal). Used solely to gate auto-lock activity
    /// recording in `handle(_:)` above.
    private func requestWasServed(_ response: ExtensionBridgeResponse) -> Bool {
        switch response {
        case .locked, .pairingRequired, .error:
            return false
        case .passkeyCreateComplete(_, _, let error):
            return error == nil
        case .passkeyGetComplete(_, _, let error):
            return error == nil
        case .pairingStarted, .paired, .credentialList, .credential, .address, .totp, .saveProposalAccepted,
             .unlockPresented, .unlockNotNeeded, .passkeyProxyStatus, .passkeyProxyEnabled,
             .passkeyCreatePending, .passkeyGetPending, .passkeyCancelled, .generatedPassword,
             .entryCreated, .acknowledged, .passwordHistory:
            return true
        }
    }

    private func response(for request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        guard vaultSession?.currentDatabase != nil || request.isAnswerableWhileLocked else {
            return .locked
        }
        switch request {
        case .openBrowserSettings(_, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else { return .pairingRequired }
            onBrowserSettingsRequested?()
            return .acknowledged
        case .reportBrowserDiagnostics(_, let report, let pairing):
            guard let browser = pairingManager.authorizedBrowser(pairing: pairing) else { return .pairingRequired }
            guard report.isValid else { return .error("invalid_browser_diagnostics") }
            browserDiagnostics.record(report, for: browser.id, receivedAt: now())
            return .acknowledged
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

        case .getFavorites(_, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            return .credentialList(favoriteEntries(in: database).map(browseSummary(for:)))

        case .listEntries(_, let category, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            guard let entries = browseEntries(category: category, in: database) else {
                return .error("unknown category")
            }
            return .credentialList(entries.map(browseSummary(for:)))

        case .searchEntries(_, let query, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .credentialList([])
            }
            let matches = EntrySearch.allEntries(in: database.rootGroup)
                .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
                .filter { EntrySearch.matches(entry: $0, query: trimmed) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return .credentialList(matches.map(browseSummary(for:)))

        case .createEntry(
            _, let entryTypeRaw, let title, let username, let password, let url,
            let cardNumber, let cardholderName, let expiry, let cvv, let notes,
            let favorite, let match, let otp, let pairing
        ):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let session = vaultSession, session.currentDatabase != nil else {
                return .locked
            }
            guard let entryType = EntryType(rawValue: entryTypeRaw) else {
                return .error("unknown entry type")
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedHolder = cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle: String
            switch entryType {
            case .login:
                resolvedTitle = EntryEditSaveLogic.resolvedTitle(draftTitle: trimmedTitle, url: url)
            case .address:
                return .error("Create addresses in MyPass using Add > Address")
            case .card:
                resolvedTitle = trimmedTitle.isEmpty ? trimmedHolder : trimmedTitle
            case .notes:
                resolvedTitle = trimmedTitle
            }
            guard !resolvedTitle.isEmpty else {
                return .error("title required")
            }
            let entry = makeCreatedEntry(
                entryType: entryType, title: resolvedTitle, username: username, password: password,
                url: url, cardNumber: cardNumber, cardholderName: cardholderName, expiry: expiry,
                cvv: cvv, notes: notes, favorite: favorite, match: match, otp: otp
            )
            session.mutate { database in
                database.rootGroup.entries.append(entry)
            }
            return .entryCreated

        case .fillAddress(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else { return .pairingRequired }
            guard let database = vaultSession?.currentDatabase else { return .locked }
            guard let destination = URLComponents(string: url),
                  ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
                  let host = destination.host, !host.isEmpty,
                  destination.user == nil, destination.password == nil else {
                return .error("Address autofill requires a website URL")
            }
            guard let entry = EntrySearch.allEntries(in: database.rootGroup).first(where: {
                $0.uuid.uuidString == id && $0.entryType == .address
                    && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
            }) else { return .error("Address not found") }
            // Addresses are deliberately reusable across websites. The extension pins this
            // explicit selection to one document/form before requesting the private values.
            vaultSession?.touchAccess(entryID: entry.uuid)
            return .address(entry.address)

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
            // `attachAllowed` folds in the app-side opt-in, not just lock state — the
            // extension mirrors this flag locally, and without the app's value in the
            // answer, turning the feature off in Settings would leave an already-attached
            // Chrome attached indefinitely (there is no push channel to tell it otherwise).
            // `enabled` is reported separately (and even while locked) so the extension can
            // learn the app-side opt-in on its own and resync its cache/attachment without
            // waiting for a service-worker restart — the app is authoritative, the
            // extension's local flag is only a cache.
            let enabled = UserDefaults.standard.bool(forKey: "passkeyProxyEnabled")
            return .passkeyProxyStatus(unlocked: unlocked, paired: true, attachAllowed: unlocked && enabled, enabled: enabled)

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
            // Chrome's attach/detach state can lag the app-side setting (the popup only
            // resyncs on certain opens), so the app itself must refuse here whenever the
            // feature is off, regardless of whatever the extension currently believes.
            guard UserDefaults.standard.bool(forKey: "passkeyProxyEnabled") else {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "MyPass passkeys are turned off in Settings")
                )
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
            // Validate the ceremony's origin before doing anything else with it — never
            // trust `originUrl` just because the extension sent it. See
            // `PasskeyCeremony.validateOrigin` for what each of the two checks defends
            // against.
            do {
                try PasskeyCeremony.validateOrigin(originUrl, requestDetailsJson: requestDetailsJson, rpId: context.rpId)
            } catch PasskeyCeremonyError.originMismatch {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "SecurityError", message: "Passkey request origin could not be verified")
                )
            } catch PasskeyCeremonyError.rpIdNotAuthorized {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "SecurityError", message: "This site is not authorized for the requested passkey relying party")
                )
            } catch {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Invalid passkey request")
                )
            }
            // Phase 1 parses and routes only — no key generation, no vault write.
            let matches = passkeyCreateCandidates(forOriginUrl: originUrl, rpId: context.rpId, in: database)
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
            // WebAuthn requires user consent before revealing that an excluded
            // credential exists (InvalidStateError). Check here, after Save/Replace,
            // rather than at the page-triggered request. Re-read the current vault:
            // another registration or sync may have added the key while UI was open.
            // This is an authenticator ownership check, not an autofill match, so a
            // live credential with URI matching disabled still prevents replacement.
            let excludedCredentialExists = EntrySearch.allEntries(in: database.rootGroup).contains { entry in
                entry.hasPasskey && entry.passkeyRelyingParty == pending.context.rpId
                    && !RecycleBinEntryFilter.isInRecycleBin(entry, database: database)
                    && entry.passkeyCredentialId.map { pending.context.excludeCredentialIds.contains($0) } == true
            }
            if excludedCredentialExists {
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "InvalidStateError", message: "A passkey for this account already exists")
                )
            }
            // Resolved from the same candidate set `.passkeyCreate` offered the popup — not
            // "any entry in the vault" — matching the pattern `fillCredential`/`getTotp`/
            // `proposeSaveTotp` already use via `matchingEntries(forURL:)`. Without this, a
            // confirm carrying an `entryId` the popup never actually listed (stale UI, a
            // forged message, a race with a since-changed candidate set) would silently
            // attach a passkey to an unrelated entry.
            let candidateIds = Set(
                passkeyCreateCandidates(forOriginUrl: pending.originUrl, rpId: pending.context.rpId, in: database)
                    .map(\.uuid.uuidString)
            )
            let targetEntry = entryId.flatMap { id -> KdbxEntry? in
                guard candidateIds.contains(id) else { return nil }
                return EntrySearch.allEntries(in: database.rootGroup)
                    .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
                    .first(where: { $0.uuid.uuidString == id })
            }
            if entryId != nil, targetEntry == nil {
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Entry not found or domain mismatch")
                )
            }
            if let targetEntry, targetEntry.passkeyPrivateKeyPEM?.isEmpty == false, !replace {
                // The ceremony is already being completed with an error on the extension
                // side here — nothing can legitimately consume a pending record left alive
                // after this point, so it is cleared like every other failure return.
                pendingPasskeyCreates.removeValue(forKey: requestId)
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
                entry.passkeyCreatedAt = timestamp
                entry.setPasskeyBackupFlags()
                entry.lastModificationTime = timestamp
                let isUpdate = targetEntry != nil
                var didWrite = false
                vaultSession?.mutate { db in
                    if isUpdate {
                        // Located across the whole tree, not just the root group — a
                        // subgroup entry would otherwise be reported as saved and
                        // silently not written.
                        guard let location = GroupTreeOperations.entryLocation(entryID: entry.uuid, in: db.rootGroup) else { return }
                        location.group.entries[location.index] = entry
                    } else {
                        db.rootGroup.entries.append(entry)
                    }
                    didWrite = true
                }
                guard didWrite else {
                    pendingPasskeyCreates.removeValue(forKey: requestId)
                    return .passkeyCreateComplete(
                        requestId: requestId, responseJson: nil,
                        error: PasskeyErrorDetails(name: "NotAllowedError", message: "Could not save the passkey")
                    )
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
            // Chrome's attach/detach state can lag the app-side setting (the popup only
            // resyncs on certain opens), so the app itself must refuse here whenever the
            // feature is off, regardless of whatever the extension currently believes.
            guard UserDefaults.standard.bool(forKey: "passkeyProxyEnabled") else {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "MyPass passkeys are turned off in Settings")
                )
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
            // Validate the ceremony's origin before doing anything else with it — never
            // trust `originUrl` just because the extension sent it. See
            // `PasskeyCeremony.validateOrigin` for what each of the two checks defends
            // against.
            do {
                try PasskeyCeremony.validateOrigin(originUrl, requestDetailsJson: requestDetailsJson, rpId: context.rpId)
            } catch PasskeyCeremonyError.originMismatch {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "SecurityError", message: "Passkey request origin could not be verified")
                )
            } catch PasskeyCeremonyError.rpIdNotAuthorized {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "SecurityError", message: "This site is not authorized for the requested passkey relying party")
                )
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

        case .recordGeneratedPassword(_, let password, let url, let createdAt, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let session = vaultSession, session.currentDatabase != nil else {
                return .locked
            }
            let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .error("password required")
            }
            let when = createdAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            session.mutate { database in
                PasswordGeneratorHistoryStore.record(password: trimmed, url: url, createdAt: when, in: &database)
            }
            return .acknowledged

        case .getGeneratedPasswordHistory(_, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            return .passwordHistory(PasswordGeneratorHistoryStore.items(in: database.rootGroup))

        case .deleteGeneratedPassword(_, let id, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let session = vaultSession, session.currentDatabase != nil else {
                return .locked
            }
            guard let uuid = UUID(uuidString: id) else {
                return .error("entry not found")
            }
            var removed = false
            session.mutate { database in
                removed = PasswordGeneratorHistoryStore.delete(id: uuid, in: &database)
            }
            return removed ? .acknowledged : .error("entry not found")

        case .generatePassword(_, let domain, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            // No vault data is needed here — rules come from the bundled
            // PasswordRulesCatalog and preferences from PasswordGeneratorDefaults,
            // neither of which lives behind the vault key. The outer guard at the
            // top of this function (`vaultSession?.currentDatabase != nil ||
            // request.isAnswerableWhileLocked`) already turned away a locked vault
            // before this case is ever reached — generatePassword.isAnswerableWhileLocked
            // is false — so there is no redundant lock re-check to write here.
            let options = PasswordGeneratorDefaults.load()
            let rules = PasswordRulesCatalog.rules(forHost: domain)
            do {
                let password = try PasswordGenerator.generate(options: options, rules: rules)
                return .generatedPassword(password: password)
            } catch PasswordGeneratorError.noCharacterClassSelected {
                // Distinct from `.unsatisfiableRules` below: this fires when the
                // user's OWN generator toggles (Settings > Password Generator) leave
                // no character class to draw from at all, independent of whatever
                // domain was passed in — the site's rule is never even reached. A
                // message that told the user "this site's requirements could not be
                // satisfied" here would send them looking for a problem with the
                // website when the fix is in their own generator settings.
                return .error("Your password generator has no character types enabled. Turn on at least one in Settings and try again.")
            } catch {
                // `.unsatisfiableRules` (a site rule no configuration can satisfy —
                // e.g. more required character classes than the configured length
                // allows room for) and any other `PasswordGeneratorError` surface
                // through the existing generic `.error(String)` response case —
                // there is no dedicated failure case for this request, matching how
                // .completePairing already reports its own failure via `.error("invalid_code")`.
                return .error("This site's password requirements could not be satisfied")
            }
        }
    }
}

/// Generated passwords live in a fixed group inside the vault so they are encrypted
/// and synced with everything else. The group stays out of the sidebar, search,
/// favorites, and site matching: these rows are history, not logins.
enum PasswordGeneratorHistoryStore {
    static let groupID = UUID(uuidString: "E4B1C0A2-7D58-4F13-9A6E-2C8F5B0D11A7")!
    static let markerKey = "MyPass.GeneratorHistory"
    static let limit = 30
    static let groupName = "Password Generator History"

    static func isHistoryGroup(_ group: KdbxGroup) -> Bool {
        group.uuid == groupID || group.customData[markerKey] == "1"
    }

    static func record(password: String, url: String, createdAt: Date, in database: inout KdbxDatabase) {
        let group = ensureGroup(in: database.rootGroup)
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: createdAt, lastModificationTime: createdAt, lastAccessTime: createdAt, locationChanged: now,
            history: []
        )
        entry.title = title(for: url)
        entry.password = password
        entry.url = url
        entry.uriMatchMode = .never
        group.entries.append(entry)
        group.lastModificationTime = now
        trim(group, database: &database, now: now)
    }

    @discardableResult
    static func delete(id: UUID, in database: inout KdbxDatabase) -> Bool {
        guard let group = find(in: database.rootGroup),
              let index = group.entries.firstIndex(where: { $0.uuid == id }) else {
            return false
        }
        group.entries.remove(at: index)
        let now = Date()
        group.lastModificationTime = now
        database.deletedObjects.append(KdbxDeletedObject(uuid: id, deletionTime: now))
        return true
    }

    static func items(in root: KdbxGroup) -> [ExtensionPasswordHistoryItem] {
        guard let group = find(in: root) else { return [] }
        return group.entries
            .sorted { $0.creationTime > $1.creationTime }
            .map { entry in
                ExtensionPasswordHistoryItem(
                    id: entry.uuid.uuidString,
                    password: entry.password,
                    url: entry.url,
                    createdAt: (entry.creationTime.timeIntervalSince1970 * 1000).rounded()
                )
            }
    }

    private static func trim(_ group: KdbxGroup, database: inout KdbxDatabase, now: Date) {
        let sorted = group.entries.sorted { $0.creationTime > $1.creationTime }
        guard sorted.count > limit else {
            group.entries = sorted
            return
        }
        group.entries = Array(sorted.prefix(limit))
        for entry in sorted.dropFirst(limit) {
            database.deletedObjects.append(KdbxDeletedObject(uuid: entry.uuid, deletionTime: now))
        }
    }

    private static func ensureGroup(in root: KdbxGroup) -> KdbxGroup {
        if let existing = find(in: root) { return existing }
        let now = Date()
        let group = KdbxGroup(
            uuid: groupID,
            name: groupName,
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: [],
            subgroups: [],
            customData: [markerKey: "1"]
        )
        root.subgroups.append(group)
        root.lastModificationTime = now
        return group
    }

    private static func find(in group: KdbxGroup) -> KdbxGroup? {
        if isHistoryGroup(group) { return group }
        for child in group.subgroups {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    private static func title(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Generated password" }
        if let host = URL(string: trimmed)?.host, !host.isEmpty { return host }
        if let host = URL(string: "https://\(trimmed)")?.host, !host.isEmpty { return host }
        return trimmed
    }
}
