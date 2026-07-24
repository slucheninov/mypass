import Foundation
import Security

public struct SFTPCredentials: Equatable, Codable {
    public var username: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?

    public init(username: String, privateKeyPEM: String, privateKeyPassphrase: String? = nil) {
        self.username = username
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
    }
}

public protocol CredentialStoring {
    func loadCredentials(forHost host: String) throws -> SFTPCredentials?
    func store(_ credentials: SFTPCredentials, forHost host: String) throws
    func removeCredentials(forHost host: String) throws
}

public enum CredentialKeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

/// Stores SFTP credentials as a generic-password Keychain item, keyed by
/// host — mirrors `BiometricKeyStore`'s (Phase 2) Keychain access pattern,
/// minus biometry: SFTP sync must be able to run in the background (e.g. an
/// autosave-triggered upload) without prompting Touch ID on every cycle, so
/// this uses a plain `kSecAttrAccessibleAfterFirstUnlock` item rather than a
/// `kSecAttrAccessControl`-gated one.
public final class CredentialKeychainStore: CredentialStoring {
    private let service = "com.mypass.sftp.credentials"

    public init() {}

    public func loadCredentials(forHost host: String) throws -> SFTPCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
        guard let credentials = try? JSONDecoder().decode(SFTPCredentials.self, from: data) else {
            throw CredentialKeychainStoreError.decodingFailed
        }
        return credentials
    }

    public func store(_ credentials: SFTPCredentials, forHost host: String) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw CredentialKeychainStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        // Delete-then-add (rather than SecItemUpdate) — same pattern as
        // BiometricKeyStore, avoiding having to diff old/new attribute
        // dictionaries for an update.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
    }

    public func removeCredentials(forHost host: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
    }
}

public final class InMemoryCredentialStore: CredentialStoring {
    private var storage: [String: SFTPCredentials] = [:]

    public init() {}

    public func loadCredentials(forHost host: String) throws -> SFTPCredentials? { storage[host] }
    public func store(_ credentials: SFTPCredentials, forHost host: String) throws { storage[host] = credentials }
    public func removeCredentials(forHost host: String) throws { storage.removeValue(forKey: host) }
}
