import Foundation
import Security

public struct ExtensionBridgeEndpoint: Codable, Equatable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }
}

public protocol ExtensionBridgeTokenStoring {
    func save(_ endpoint: ExtensionBridgeEndpoint) throws
    func load() throws -> ExtensionBridgeEndpoint?
    func clear() throws
}

public enum ExtensionBridgeTokenStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

public final class InMemoryExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    private var stored: ExtensionBridgeEndpoint?

    public init() {}

    public func save(_ endpoint: ExtensionBridgeEndpoint) throws {
        stored = endpoint
    }

    public func load() throws -> ExtensionBridgeEndpoint? {
        stored
    }

    public func clear() throws {
        stored = nil
    }
}

/// Cross-process Keychain store for the live loopback endpoint. Unlike
/// `CredentialKeychainStore` (SyncKit), this store is read by `ChromeHost` — a
/// separate executable outside the MyPass.app bundle with a different code
/// signature — so it MUST use an explicit shared access group rather than the
/// app's implicit default one. `ChromeHost.entitlements` (Task 8) must declare
/// membership in the same access group, and both targets must be signed with
/// the same Apple Developer Team ID for cross-process Keychain access to work;
/// that signing requirement cannot be verified by an automated test.
public final class ExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    private let service = "com.mypass.extensionbridge.endpoint"
    private let account = "loopback"
    private let accessGroup = "com.mypass.app.keychain"

    public init() {}

    public func save(_ endpoint: ExtensionBridgeEndpoint) throws {
        guard let data = try? JSONEncoder().encode(endpoint) else {
            throw ExtensionBridgeTokenStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
    }

    public func load() throws -> ExtensionBridgeEndpoint? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
        guard let endpoint = try? JSONDecoder().decode(ExtensionBridgeEndpoint.self, from: data) else {
            throw ExtensionBridgeTokenStoreError.decodingFailed
        }
        return endpoint
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
