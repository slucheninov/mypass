import Foundation

// MARK: - Requests

public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case getTotp(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case proposeSaveTotp(token: String, url: String, otpauthOrSecret: String, entryId: String?, pairing: String?)
    case startPairing(token: String, browser: String?)
    case completePairing(token: String, code: String)
    case requestUnlock(token: String, pairing: String?)
    case getPasskeyProxyStatus(token: String, pairing: String?)
    case setPasskeyProxyEnabled(token: String, enabled: Bool, pairing: String?)
    case passkeyCreate(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyCreateConfirm(token: String, requestId: Int, entryId: String?, replace: Bool, pairing: String?)
    case passkeyGet(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyGetApprove(token: String, requestId: Int, entryId: String, pairing: String?)
    case passkeyCancel(token: String, requestId: Int, pairing: String?)
}

extension ExtensionBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId
        case enabled, requestId, requestDetailsJson, originUrl, replace
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
        case .getPasskeyProxyStatus:
            return true
        case .getCredentials, .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp, .startPairing, .completePairing,
             .setPasskeyProxyEnabled, .passkeyCreate, .passkeyCreateConfirm, .passkeyGet, .passkeyGetApprove, .passkeyCancel:
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

    public init(id: String, title: String, username: String, hasTotp: Bool, hasPasskey: Bool) {
        self.id = id
        self.title = title
        self.username = username
        self.hasTotp = hasTotp
        self.hasPasskey = hasPasskey
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

// MARK: - Responses

public enum ExtensionBridgeResponse: Equatable {
    case locked
    case pairingRequired
    case pairingStarted
    case paired(secret: String)
    case credentialList([ExtensionCredentialSummary])
    case credential(username: String, password: String, totp: String?)
    case totp(code: String)
    case saveProposalAccepted
    case unlockPresented
    case unlockNotNeeded
    case passkeyProxyStatus(unlocked: Bool, paired: Bool, attachAllowed: Bool)
    case passkeyProxyEnabled(enabled: Bool)
    case passkeyCreatePending(requestId: Int, rpId: String, rpName: String, matches: [ExtensionCredentialSummary])
    case passkeyCreateComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyGetPending(requestId: Int, rpId: String, matches: [ExtensionCredentialSummary])
    case passkeyGetComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyCancelled(requestId: Int)
    case error(String)
}

extension ExtensionBridgeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, message, secret, code
        case unlocked, paired, attachAllowed, enabled, requestId, rpId, rpName, matches, responseJson, error
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
        case "credential":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let totp = try container.decodeIfPresent(String.self, forKey: .totp)
            self = .credential(username: username, password: password, totp: totp)
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
            self = .passkeyProxyStatus(unlocked: unlocked, paired: paired, attachAllowed: attachAllowed)
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
        case .credential(let username, let password, let totp):
            try container.encode("credential", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(totp, forKey: .totp)
        case .totp(let code):
            try container.encode("totp", forKey: .type)
            try container.encode(code, forKey: .code)
        case .saveProposalAccepted:
            try container.encode("saveProposalAccepted", forKey: .type)
        case .unlockPresented:
            try container.encode("unlockPresented", forKey: .type)
        case .unlockNotNeeded:
            try container.encode("unlockNotNeeded", forKey: .type)
        case .passkeyProxyStatus(let unlocked, let paired, let attachAllowed):
            try container.encode("passkeyProxyStatus", forKey: .type)
            try container.encode(unlocked, forKey: .unlocked)
            try container.encode(paired, forKey: .paired)
            try container.encode(attachAllowed, forKey: .attachAllowed)
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
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
