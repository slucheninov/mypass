import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Supplies the symmetric key that encrypts note drafts at rest.
protocol DraftKeyProviding {
    func loadOrCreateKey() throws -> SymmetricKey
}

enum DraftKeyError: Error {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)
    case malformedKey
}

/// One app-wide 256-bit key kept in the Keychain.
///
/// Access group: `com.mypass.app.biometric`, the app-only group declared in
/// MyPass.entitlements. ChromeHost's entitlements list only `com.mypass.app.keychain`,
/// so the native messaging host (and anything it relays for) cannot read this key.
/// `com.mypass.app.keychain` is deliberately NOT used for that reason. The group name
/// is historical: the item is a plain generic password and carries NO SecAccessControl,
/// no biometry and no user-presence flag, so saving a draft never raises Touch ID.
/// Only `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is set: the key is unreadable
/// while the Mac is locked and never leaves the device (no iCloud Keychain, no backup
/// restore onto another machine).
///
/// Every query sets `kSecAttrAccessGroup` explicitly; a sandboxed app with a
/// keychain-access-groups entitlement otherwise gets errSecMissingEntitlement (-34018),
/// same as `BiometricKeyStore`.
final class KeychainDraftKeyProvider: DraftKeyProviding {
    private let service: String
    private let account: String
    private let accessGroup = "com.mypass.app.biometric"

    init(service: String = "com.mypass.app.drafts", account: String = "draft-key-v1") {
        self.service = service
        self.account = account
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try read() {
            guard data.count == 32 else { throw DraftKeyError.malformedKey }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read(), existing.count == 32 {
            // Lost a creation race with another caller: use the stored key.
            return SymmetricKey(data: existing)
        }
        guard status == errSecSuccess else { throw DraftKeyError.keychainWrite(status) }
        return key
    }

    private func read() throws -> Data? {
        // The item has no access control, so this never prompts; interactionNotAllowed makes
        // that a guarantee (a failure instead of a dialog) if the item were ever re-created
        // with a protected ACL.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DraftKeyError.keychainRead(status) }
        return result as? Data
    }
}

/// Test double: a fixed key, or a provider that always fails.
final class InMemoryDraftKeyProvider: DraftKeyProviding {
    private let key: SymmetricKey?

    init(key: SymmetricKey? = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        guard let key else { throw DraftKeyError.keychainRead(errSecItemNotFound) }
        return key
    }
}
