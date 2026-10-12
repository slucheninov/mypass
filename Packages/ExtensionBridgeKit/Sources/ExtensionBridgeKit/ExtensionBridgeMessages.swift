import Foundation

// MARK: - Requests

public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    /// Favorite entries, for a popup opened where there is no site to match
    /// (`chrome://extensions`, the new tab, a tab with no URL).
    case getFavorites(token: String, pairing: String?)
    /// Vault browse for the popup category menu. `category` is one of
    /// favorites, all, logins, codes, passkeys, addresses, cards, notes.
    case listEntries(token: String, category: String, pairing: String?)
    /// Live search from the popup. Matches title, username, URL, and notes.
    case searchEntries(token: String, query: String, pairing: String?)
    /// Creates one entry from the extension's new-item window. `entryType` is Login,
    /// Card, or Notes. `favorite`, `match`, and `otp` are the editor fields the app
    /// saves on a new entry. `match` is a `URIMatchMode` raw value; blank or unknown
    /// keeps the vault default. `otp` is an otpauth URL or a raw secret.
    case createEntry(
        token: String,
        entryType: String,
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
        otp: String,
        pairing: String?
    )
    /// An explicit popup selection; addresses are not tied to a saved website.
    case fillAddress(token: String, id: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case getTotp(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    /// Writes a page identifier onto an existing item for this URL. An empty login
    /// becomes the username. A login that is already set is left in place and the
    /// value is stored as a custom field named by `fieldKey` (`Phone`, `Email`, or `Login`).
    case addEntryIdentifier(token: String, id: String, url: String, value: String, fieldKey: String, pairing: String?)
    case proposeSaveTotp(token: String, url: String, otpauthOrSecret: String, entryId: String?, pairing: String?)
    case startPairing(token: String, browser: String?)
    case completePairing(token: String, code: String)
    case requestUnlock(token: String, pairing: String?)
    /// Locks the unlocked vault. The service worker accepts this only from the popup.
    case lockVault(token: String, pairing: String?)
    /// Brings the MyPass window forward, locked or unlocked. The service worker
    /// accepts this only from the popup, so a page cannot steal focus.
    case openApp(token: String, pairing: String?)
    case openBrowserSettings(token: String, pairing: String?)
    case reportBrowserDiagnostics(token: String, report: BrowserDiagnosticsReport, pairing: String?)
    case getPasskeyProxyStatus(token: String, pairing: String?)
    case setPasskeyProxyEnabled(token: String, enabled: Bool, pairing: String?)
    case passkeyCreate(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyCreateConfirm(token: String, requestId: Int, entryId: String?, replace: Bool, pairing: String?)
    case passkeyGet(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyGetApprove(token: String, requestId: Int, entryId: String, pairing: String?)
    case passkeyCancel(token: String, requestId: Int, pairing: String?)
    case generatePassword(token: String, domain: String, pairing: String?)
    /// Appends one generated password to the vault's generator history.
    /// `createdAt` is Unix epoch milliseconds. Blank means "now".
    case recordGeneratedPassword(token: String, password: String, url: String, createdAt: Double?, pairing: String?)
    /// Newest first. The entries live in the vault, not in the browser profile.
    case getGeneratedPasswordHistory(token: String, pairing: String?)
    /// Removes one generator-history row by its entry id.
    case deleteGeneratedPassword(token: String, id: String, pairing: String?)
}

extension ExtensionBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId, value, fieldKey
        case enabled, requestId, requestDetailsJson, originUrl, replace, domain
        case category, query, entryType, title, cardNumber, cardholderName, expiry, cvv, notes
        case favorite, match, otp, createdAt, report
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let token = try container.decode(String.self, forKey: .token)
        switch type {
        case "getCredentials":
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getCredentials(token: token, url: url, pairing: pairing)
        case "getFavorites":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getFavorites(token: token, pairing: pairing)
        case "listEntries":
            let category = try container.decode(String.self, forKey: .category)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .listEntries(token: token, category: category, pairing: pairing)
        case "searchEntries":
            let query = try container.decode(String.self, forKey: .query)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .searchEntries(token: token, query: query, pairing: pairing)
        case "createEntry":
            let entryType = try container.decode(String.self, forKey: .entryType)
            let title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            let username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
            let password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
            let url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            let cardNumber = try container.decodeIfPresent(String.self, forKey: .cardNumber) ?? ""
            let cardholderName = try container.decodeIfPresent(String.self, forKey: .cardholderName) ?? ""
            let expiry = try container.decodeIfPresent(String.self, forKey: .expiry) ?? ""
            let cvv = try container.decodeIfPresent(String.self, forKey: .cvv) ?? ""
            let notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
            let favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
            let match = try container.decodeIfPresent(String.self, forKey: .match) ?? ""
            let otp = try container.decodeIfPresent(String.self, forKey: .otp) ?? ""
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .createEntry(
                token: token, entryType: entryType, title: title, username: username, password: password,
                url: url, cardNumber: cardNumber, cardholderName: cardholderName, expiry: expiry,
                cvv: cvv, notes: notes, favorite: favorite, match: match, otp: otp, pairing: pairing
            )
        case "fillAddress":
            self = .fillAddress(
                token: token, id: try container.decode(String.self, forKey: .id),
                url: try container.decode(String.self, forKey: .url),
                pairing: try container.decodeIfPresent(String.self, forKey: .pairing)
            )
        case "fillCredential":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .fillCredential(token: token, id: id, url: url, pairing: pairing)
        case "getTotp":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getTotp(token: token, id: id, url: url, pairing: pairing)
        case "proposeSaveLogin":
            let url = try container.decode(String.self, forKey: .url)
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .proposeSaveLogin(token: token, url: url, username: username, password: password, pairing: pairing)
        case "addEntryIdentifier":
            self = .addEntryIdentifier(
                token: token,
                id: try container.decode(String.self, forKey: .id),
                url: try container.decode(String.self, forKey: .url),
                value: try container.decode(String.self, forKey: .value),
                fieldKey: try container.decode(String.self, forKey: .fieldKey),
                pairing: try container.decodeIfPresent(String.self, forKey: .pairing)
            )
        case "proposeSaveTotp":
            let url = try container.decode(String.self, forKey: .url)
            let otpauthOrSecret = try container.decode(String.self, forKey: .otpauthOrSecret)
            let entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .proposeSaveTotp(token: token, url: url, otpauthOrSecret: otpauthOrSecret, entryId: entryId, pairing: pairing)
        case "startPairing":
            let browser = try container.decodeIfPresent(String.self, forKey: .browser)
            self = .startPairing(token: token, browser: browser)
        case "completePairing":
            let code = try container.decode(String.self, forKey: .code)
            self = .completePairing(token: token, code: code)
        case "requestUnlock":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .requestUnlock(token: token, pairing: pairing)
        case "lockVault":
            self = .lockVault(token: token, pairing: try container.decodeIfPresent(String.self, forKey: .pairing))
        case "openApp":
            self = .openApp(token: token, pairing: try container.decodeIfPresent(String.self, forKey: .pairing))
        case "openBrowserSettings":
            self = .openBrowserSettings(token: token, pairing: try container.decodeIfPresent(String.self, forKey: .pairing))
        case "reportBrowserDiagnostics":
            self = .reportBrowserDiagnostics(token: token, report: try container.decode(BrowserDiagnosticsReport.self, forKey: .report), pairing: try container.decodeIfPresent(String.self, forKey: .pairing))
        case "getPasskeyProxyStatus":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getPasskeyProxyStatus(token: token, pairing: pairing)
        case "setPasskeyProxyEnabled":
            let enabled = try container.decode(Bool.self, forKey: .enabled)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .setPasskeyProxyEnabled(token: token, enabled: enabled, pairing: pairing)
        case "passkeyCreate":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let requestDetailsJson = try container.decode(String.self, forKey: .requestDetailsJson)
            let originUrl = try container.decode(String.self, forKey: .originUrl)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCreate(
                token: token, requestId: requestId, requestDetailsJson: requestDetailsJson,
                originUrl: originUrl, pairing: pairing
            )
        case "passkeyCreateConfirm":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
            let replace = try container.decodeIfPresent(Bool.self, forKey: .replace) ?? false
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCreateConfirm(
                token: token, requestId: requestId, entryId: entryId, replace: replace, pairing: pairing
            )
        case "passkeyGet":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let requestDetailsJson = try container.decode(String.self, forKey: .requestDetailsJson)
            let originUrl = try container.decode(String.self, forKey: .originUrl)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyGet(
                token: token, requestId: requestId, requestDetailsJson: requestDetailsJson,
                originUrl: originUrl, pairing: pairing
            )
        case "passkeyGetApprove":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let entryId = try container.decode(String.self, forKey: .entryId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyGetApprove(token: token, requestId: requestId, entryId: entryId, pairing: pairing)
        case "passkeyCancel":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCancel(token: token, requestId: requestId, pairing: pairing)
        case "generatePassword":
            let domain = try container.decode(String.self, forKey: .domain)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .generatePassword(token: token, domain: domain, pairing: pairing)
        case "recordGeneratedPassword":
            let password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
            let url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            let createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .recordGeneratedPassword(
                token: token, password: password, url: url, createdAt: createdAt, pairing: pairing
            )
        case "getGeneratedPasswordHistory":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getGeneratedPasswordHistory(token: token, pairing: pairing)
        case "deleteGeneratedPassword":
            let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .deleteGeneratedPassword(token: token, id: id, pairing: pairing)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown ExtensionBridgeRequest type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getCredentials(let token, let url, let pairing):
            try container.encode("getCredentials", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .getFavorites(let token, let pairing):
            try container.encode("getFavorites", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .listEntries(let token, let category, let pairing):
            try container.encode("listEntries", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(category, forKey: .category)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .searchEntries(let token, let query, let pairing):
            try container.encode("searchEntries", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(query, forKey: .query)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .createEntry(
            let token, let entryType, let title, let username, let password, let url,
            let cardNumber, let cardholderName, let expiry, let cvv, let notes,
            let favorite, let match, let otp, let pairing
        ):
            try container.encode("createEntry", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(entryType, forKey: .entryType)
            try container.encode(title, forKey: .title)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encode(url, forKey: .url)
            try container.encode(cardNumber, forKey: .cardNumber)
            try container.encode(cardholderName, forKey: .cardholderName)
            try container.encode(expiry, forKey: .expiry)
            try container.encode(cvv, forKey: .cvv)
            try container.encode(notes, forKey: .notes)
            try container.encode(favorite, forKey: .favorite)
            try container.encode(match, forKey: .match)
            try container.encode(otp, forKey: .otp)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .fillAddress(let token, let id, let url, let pairing):
            try container.encode("fillAddress", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .fillCredential(let token, let id, let url, let pairing):
            try container.encode("fillCredential", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .getTotp(let token, let id, let url, let pairing):
            try container.encode("getTotp", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .proposeSaveLogin(let token, let url, let username, let password, let pairing):
            try container.encode("proposeSaveLogin", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .addEntryIdentifier(let token, let id, let url, let value, let fieldKey, let pairing):
            try container.encode("addEntryIdentifier", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encode(value, forKey: .value)
            try container.encode(fieldKey, forKey: .fieldKey)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .proposeSaveTotp(let token, let url, let otpauthOrSecret, let entryId, let pairing):
            try container.encode("proposeSaveTotp", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(otpauthOrSecret, forKey: .otpauthOrSecret)
            try container.encodeIfPresent(entryId, forKey: .entryId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .startPairing(let token, let browser):
            try container.encode("startPairing", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(browser, forKey: .browser)
        case .completePairing(let token, let code):
            try container.encode("completePairing", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(code, forKey: .code)
        case .requestUnlock(let token, let pairing):
            try container.encode("requestUnlock", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .lockVault(let token, let pairing):
            try container.encode("lockVault", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .openApp(let token, let pairing):
            try container.encode("openApp", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .openBrowserSettings(let token, let pairing):
            try container.encode("openBrowserSettings", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .reportBrowserDiagnostics(let token, let report, let pairing):
            try container.encode("reportBrowserDiagnostics", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(report, forKey: .report)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .getPasskeyProxyStatus(let token, let pairing):
            try container.encode("getPasskeyProxyStatus", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .setPasskeyProxyEnabled(let token, let enabled, let pairing):
            try container.encode("setPasskeyProxyEnabled", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(enabled, forKey: .enabled)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCreate(let token, let requestId, let requestDetailsJson, let originUrl, let pairing):
            try container.encode("passkeyCreate", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(requestDetailsJson, forKey: .requestDetailsJson)
            try container.encode(originUrl, forKey: .originUrl)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCreateConfirm(let token, let requestId, let entryId, let replace, let pairing):
            try container.encode("passkeyCreateConfirm", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(entryId, forKey: .entryId)
            try container.encode(replace, forKey: .replace)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyGet(let token, let requestId, let requestDetailsJson, let originUrl, let pairing):
            try container.encode("passkeyGet", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(requestDetailsJson, forKey: .requestDetailsJson)
            try container.encode(originUrl, forKey: .originUrl)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyGetApprove(let token, let requestId, let entryId, let pairing):
            try container.encode("passkeyGetApprove", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(entryId, forKey: .entryId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCancel(let token, let requestId, let pairing):
            try container.encode("passkeyCancel", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .generatePassword(let token, let domain, let pairing):
            try container.encode("generatePassword", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(domain, forKey: .domain)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .recordGeneratedPassword(let token, let password, let url, let createdAt, let pairing):
            try container.encode("recordGeneratedPassword", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(password, forKey: .password)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(createdAt, forKey: .createdAt)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .getGeneratedPasswordHistory(let token, let pairing):
            try container.encode("getGeneratedPasswordHistory", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .deleteGeneratedPassword(let token, let id, let pairing):
            try container.encode("deleteGeneratedPassword", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        }
    }
}

public extension ExtensionBridgeRequest {
    /// The requests the app answers even while the vault is locked. Everything else is
    /// rejected with `.locked` before it reaches a handler.
    ///
    /// The switch is deliberately exhaustive with no `default`: a new request case must
    /// make an explicit decision here rather than silently inheriting an exemption.
    /// Keep this list as short as the spec allows.
    var isAnswerableWhileLocked: Bool {
        switch self {
        case .requestUnlock:
            return true
        // Exists specifically to report lock state to the extension's proxy-attach
        // lifecycle. Answering it with a blanket `.locked` would make it useless.
        case .getPasskeyProxyStatus, .openBrowserSettings, .reportBrowserDiagnostics, .openApp:
            return true
        case .getCredentials, .getFavorites, .listEntries, .searchEntries, .createEntry, .addEntryIdentifier, .fillAddress, .fillCredential, .getTotp,
             .proposeSaveLogin, .proposeSaveTotp, .startPairing, .completePairing, .lockVault,
             .setPasskeyProxyEnabled, .passkeyCreate, .passkeyCreateConfirm, .passkeyGet, .passkeyGetApprove, .passkeyCancel,
             .generatePassword, .recordGeneratedPassword, .getGeneratedPasswordHistory, .deleteGeneratedPassword:
            return false
        }
    }

    /// Whether handling this request should reset the app's idle auto-lock timer.
    ///
    /// A user working entirely in the browser extension never touches the MyPass window,
    /// so the idle timer's only other reset source (`NSEvent` key/mouse monitoring in
    /// `MyPassApp.swift`) never fires for them — the vault would silently re-lock under an
    /// active user. The fix is to reset on extension traffic too, but ONLY on requests that
    /// cannot be produced without a deliberate user gesture. Background/status polling and
    /// anything a page can trigger on its own — proxy status checks, the app-side toggle,
    /// the pairing handshake, and (critically) `getCredentials`/`passkeyCreate`/`passkeyGet`
    /// — must NOT reset the timer: `content.js` fires `requestCredentials()` automatically
    /// whenever a login form is found (runs at `<all_urls>`, all frames), and
    /// `background.js` forwards every `webAuthenticationProxy` create/get event, which page
    /// script triggers on its own timing via `navigator.credentials.create/get()` (including
    /// conditional mediation at page load, with no user gesture at all). Resetting on those
    /// would let a hostile or merely noisy background tab defeat idle auto-lock entirely.
    ///
    /// Classification rule: resets only if the request cannot be produced without a
    /// deliberate user gesture (verified per case against the content-script
    /// `trustedClickHandler`/`isTrustedActivation` guards, or a popup button click).
    ///
    /// The switch is deliberately exhaustive with no `default`, mirroring
    /// `isAnswerableWhileLocked` above: a new request case must make an explicit decision
    /// here rather than silently inheriting one.
    var resetsAutoLockTimer: Bool {
        switch self {
        // Gesture-gated: a popup button click (`fillCredential`, `getTotp`,
        // `proposeSaveLogin`, `proposeSaveTotp`, `passkeyCreateConfirm`,
        // `passkeyGetApprove`, `requestUnlock`) — none of these can fire on a page's
        // own timing.
        case .fillAddress, .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp,
             .passkeyCreateConfirm, .passkeyGetApprove, .requestUnlock, .generatePassword,
             .getFavorites, .listEntries, .searchEntries, .createEntry, .addEntryIdentifier,
             .recordGeneratedPassword, .getGeneratedPasswordHistory, .deleteGeneratedPassword:
            return true
        // Page-triggerable, no user gesture required: `content.js`'s automatic
        // `requestCredentials()` on any detected login form, and the
        // `webAuthenticationProxy` create/get events `background.js` forwards for
        // page-initiated `navigator.credentials.create/get()` calls.
        case .getCredentials, .passkeyCreate, .passkeyGet:
            return false
        // Can all fire without the user acting: status polling, the app-side toggle
        // mirrored from Settings, and the pairing handshake driven by the browser side.
        // `lockVault` is a popup gesture, but its job is to lock, so it must not
        // record activity and keep the idle timer alive.
        case .getPasskeyProxyStatus, .setPasskeyProxyEnabled, .startPairing, .completePairing, .passkeyCancel,
             .openBrowserSettings, .reportBrowserDiagnostics, .lockVault, .openApp:
            return false
        }
    }
}

// MARK: - Shared value types

public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String
    public let hasTotp: Bool
    public let hasPasskey: Bool
    /// Set on favorite rows so the popup can open the saved site. Omitted on
    /// ordinary site matches, which already know the page they were matched to.
    public let url: String?
    /// Login, Address, Card, or Notes. Omitted on site-match rows.
    public let entryType: String?
    /// Non-protected custom field values. The popup compares a value typed on the
    /// page with these and with `username`. Protected fields are not included.
    public let identifiers: [String]

    public init(
        id: String, title: String, username: String, hasTotp: Bool, hasPasskey: Bool,
        url: String? = nil, entryType: String? = nil, identifiers: [String] = []
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.hasTotp = hasTotp
        self.hasPasskey = hasPasskey
        self.url = url
        self.entryType = entryType
        self.identifiers = identifiers
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, username, hasTotp, hasPasskey, url, entryType, identifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        username = try container.decode(String.self, forKey: .username)
        hasTotp = try container.decode(Bool.self, forKey: .hasTotp)
        hasPasskey = try container.decode(Bool.self, forKey: .hasPasskey)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        entryType = try container.decodeIfPresent(String.self, forKey: .entryType)
        identifiers = try container.decodeIfPresent([String].self, forKey: .identifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(username, forKey: .username)
        try container.encode(hasTotp, forKey: .hasTotp)
        try container.encode(hasPasskey, forKey: .hasPasskey)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(entryType, forKey: .entryType)
        if !identifiers.isEmpty {
            try container.encode(identifiers, forKey: .identifiers)
        }
    }
}

/// Mirrors Chrome's `DOMExceptionDetails` shape (`name`/`message`) exactly, so
/// `background.js` can hand it straight to `completeCreateRequest`/`completeGetRequest`
/// without remapping.
public struct PasskeyErrorDetails: Codable, Equatable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

/// One row of the password generator history stored in the vault.
/// `createdAt` is Unix epoch milliseconds, the same unit the extension already uses.
public struct ExtensionPasswordHistoryItem: Codable, Equatable {
    public var id: String
    public var password: String
    public var url: String
    public var createdAt: Double

    public init(id: String, password: String, url: String, createdAt: Double) {
        self.id = id
        self.password = password
        self.url = url
        self.createdAt = createdAt
    }
}

// MARK: - Responses

public enum ExtensionBridgeResponse: Equatable {
    case locked
    case pairingRequired
    case pairingStarted
    case paired(secret: String)
    case credentialList([ExtensionCredentialSummary])
    case address(ExtensionAddress)
    /// `urls` are the item's saved websites. The extension uses them only to
    /// decide whether a later paste or copy is still on one of those sites.
    /// Omitted on the wire when empty so older callers stay valid.
    case credential(username: String, password: String, totp: String?, urls: [String] = [])
    case totp(code: String)
    case saveProposalAccepted
    case unlockPresented
    case unlockNotNeeded
    case passkeyProxyStatus(unlocked: Bool, paired: Bool, attachAllowed: Bool, enabled: Bool)
    case passkeyProxyEnabled(enabled: Bool)
    case passkeyCreatePending(requestId: Int, rpId: String, rpName: String, matches: [ExtensionCredentialSummary])
    case passkeyCreateComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyGetPending(requestId: Int, rpId: String, matches: [ExtensionCredentialSummary])
    case passkeyGetComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyCancelled(requestId: Int)
    case generatedPassword(password: String)
    /// The popup created an entry. The list is re-queried rather than trusting an echo.
    case entryCreated
    /// Generator history was recorded or deleted. The wire type is `ok`.
    case acknowledged
    /// Newest first. Passwords are included because the history window reveals them on demand.
    case passwordHistory([ExtensionPasswordHistoryItem])
    case error(String)
}

extension ExtensionBridgeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, urls, message, secret, code
        case unlocked, paired, attachAllowed, enabled, requestId, rpId, rpName, matches, responseJson, error
        case entries, address
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "locked":
            self = .locked
        case "pairingRequired":
            self = .pairingRequired
        case "pairingStarted":
            self = .pairingStarted
        case "paired":
            let secret = try container.decode(String.self, forKey: .secret)
            self = .paired(secret: secret)
        case "credentialList":
            let credentials = try container.decode([ExtensionCredentialSummary].self, forKey: .credentials)
            self = .credentialList(credentials)
        case "address":
            self = .address(try container.decode(ExtensionAddress.self, forKey: .address))
        case "credential":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let totp = try container.decodeIfPresent(String.self, forKey: .totp)
            let urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
            self = .credential(username: username, password: password, totp: totp, urls: urls)
        case "totp":
            let code = try container.decode(String.self, forKey: .code)
            self = .totp(code: code)
        case "saveProposalAccepted":
            self = .saveProposalAccepted
        case "unlockPresented":
            self = .unlockPresented
        case "unlockNotNeeded":
            self = .unlockNotNeeded
        case "passkeyProxyStatus":
            let unlocked = try container.decode(Bool.self, forKey: .unlocked)
            let paired = try container.decode(Bool.self, forKey: .paired)
            let attachAllowed = try container.decode(Bool.self, forKey: .attachAllowed)
            // Tolerant decode: production always encodes `enabled` (see below), but a
            // decoder must survive an older wire shape without it — the extension's own
            // fallback (treat a missing field as "no authority yet") lives in background.js,
            // not here; this default only keeps the type itself decodable.
            let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            self = .passkeyProxyStatus(unlocked: unlocked, paired: paired, attachAllowed: attachAllowed, enabled: enabled)
        case "passkeyProxyEnabled":
            let enabled = try container.decode(Bool.self, forKey: .enabled)
            self = .passkeyProxyEnabled(enabled: enabled)
        case "passkeyCreatePending":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let rpId = try container.decode(String.self, forKey: .rpId)
            let rpName = try container.decode(String.self, forKey: .rpName)
            let matches = try container.decode([ExtensionCredentialSummary].self, forKey: .matches)
            self = .passkeyCreatePending(requestId: requestId, rpId: rpId, rpName: rpName, matches: matches)
        case "passkeyCreateComplete":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let responseJson = try container.decodeIfPresent(String.self, forKey: .responseJson)
            let error = try container.decodeIfPresent(PasskeyErrorDetails.self, forKey: .error)
            self = .passkeyCreateComplete(requestId: requestId, responseJson: responseJson, error: error)
        case "passkeyGetPending":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let rpId = try container.decode(String.self, forKey: .rpId)
            let matches = try container.decode([ExtensionCredentialSummary].self, forKey: .matches)
            self = .passkeyGetPending(requestId: requestId, rpId: rpId, matches: matches)
        case "passkeyGetComplete":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let responseJson = try container.decodeIfPresent(String.self, forKey: .responseJson)
            let error = try container.decodeIfPresent(PasskeyErrorDetails.self, forKey: .error)
            self = .passkeyGetComplete(requestId: requestId, responseJson: responseJson, error: error)
        case "passkeyCancelled":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            self = .passkeyCancelled(requestId: requestId)
        case "generatedPassword":
            let password = try container.decode(String.self, forKey: .password)
            self = .generatedPassword(password: password)
        case "entryCreated":
            self = .entryCreated
        case "ok":
            self = .acknowledged
        case "generatedPasswordHistory":
            let entries = try container.decodeIfPresent([ExtensionPasswordHistoryItem].self, forKey: .entries) ?? []
            self = .passwordHistory(entries)
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown ExtensionBridgeResponse type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .locked:
            try container.encode("locked", forKey: .type)
        case .pairingRequired:
            try container.encode("pairingRequired", forKey: .type)
        case .pairingStarted:
            try container.encode("pairingStarted", forKey: .type)
        case .paired(let secret):
            try container.encode("paired", forKey: .type)
            try container.encode(secret, forKey: .secret)
        case .credentialList(let credentials):
            try container.encode("credentialList", forKey: .type)
            try container.encode(credentials, forKey: .credentials)
        case .address(let address):
            try container.encode("address", forKey: .type)
            try container.encode(address, forKey: .address)
        case .credential(let username, let password, let totp, let urls):
            try container.encode("credential", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(totp, forKey: .totp)
            if !urls.isEmpty {
                try container.encode(urls, forKey: .urls)
            }
        case .totp(let code):
            try container.encode("totp", forKey: .type)
            try container.encode(code, forKey: .code)
        case .saveProposalAccepted:
            try container.encode("saveProposalAccepted", forKey: .type)
        case .unlockPresented:
            try container.encode("unlockPresented", forKey: .type)
        case .unlockNotNeeded:
            try container.encode("unlockNotNeeded", forKey: .type)
        case .passkeyProxyStatus(let unlocked, let paired, let attachAllowed, let enabled):
            try container.encode("passkeyProxyStatus", forKey: .type)
            try container.encode(unlocked, forKey: .unlocked)
            try container.encode(paired, forKey: .paired)
            try container.encode(attachAllowed, forKey: .attachAllowed)
            try container.encode(enabled, forKey: .enabled)
        case .passkeyProxyEnabled(let enabled):
            try container.encode("passkeyProxyEnabled", forKey: .type)
            try container.encode(enabled, forKey: .enabled)
        case .passkeyCreatePending(let requestId, let rpId, let rpName, let matches):
            try container.encode("passkeyCreatePending", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(rpId, forKey: .rpId)
            try container.encode(rpName, forKey: .rpName)
            try container.encode(matches, forKey: .matches)
        case .passkeyCreateComplete(let requestId, let responseJson, let error):
            try container.encode("passkeyCreateComplete", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(responseJson, forKey: .responseJson)
            try container.encodeIfPresent(error, forKey: .error)
        case .passkeyGetPending(let requestId, let rpId, let matches):
            try container.encode("passkeyGetPending", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(rpId, forKey: .rpId)
            try container.encode(matches, forKey: .matches)
        case .passkeyGetComplete(let requestId, let responseJson, let error):
            try container.encode("passkeyGetComplete", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(responseJson, forKey: .responseJson)
            try container.encodeIfPresent(error, forKey: .error)
        case .passkeyCancelled(let requestId):
            try container.encode("passkeyCancelled", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
        case .generatedPassword(let password):
            try container.encode("generatedPassword", forKey: .type)
            try container.encode(password, forKey: .password)
        case .entryCreated:
            try container.encode("entryCreated", forKey: .type)
        case .acknowledged:
            try container.encode("ok", forKey: .type)
        case .passwordHistory(let entries):
            try container.encode("generatedPasswordHistory", forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
