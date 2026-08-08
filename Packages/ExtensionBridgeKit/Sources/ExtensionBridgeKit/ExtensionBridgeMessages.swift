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
}

extension ExtensionBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId
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
        case .getCredentials, .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp, .startPairing, .completePairing:
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

    public init(id: String, title: String, username: String, hasTotp: Bool) {
        self.id = id
        self.title = title
        self.username = username
        self.hasTotp = hasTotp
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
    case error(String)
}

extension ExtensionBridgeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, message, secret, code
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
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
