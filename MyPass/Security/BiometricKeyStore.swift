import Foundation
import Security

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws
    func retrieve(account: String) throws -> Data?
    func remove(account: String) throws
    func hasStoredKey(account: String) throws -> Bool
}

enum BiometricKeyStoreError: Error {
    case keychainWrite(OSStatus)
    case keychainRead(OSStatus)
}

final class BiometricKeyStore: BiometricKeyStoring {
    private let service: String
    // App-only access group, declared in MyPass.entitlements. Sandboxed apps with a
    // keychain-access-groups entitlement must set kSecAttrAccessGroup explicitly on
    // every query — omitting it produces errSecMissingEntitlement (-34018).
    // Mirrors the file-based Keychain pattern in ExtensionPairingStore.swift.
    // SecAccessControl / kSecUseDataProtectionKeychain require a real Development
    // Team and fail on ad-hoc ("Sign to Run Locally") builds; device auth is gated
    // via LAContext at unlock time instead.
    private let accessGroup = "com.mypass.app.biometric"

    init(service: String = "com.mypass.app.biometric") {
        self.service = service
    }

    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws {
        // accessControl is recorded by FakeBiometricKeyStore and drives LAContext policy
        // at unlock time; it is not applied to Keychain (SecAccessControl requires a
        // signed app with a Development Team on macOS).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = derivedKey
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func retrieve(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return result as? Data
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func hasStoredKey(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return true
    }
}

final class FakeBiometricKeyStore: BiometricKeyStoring {
    private var storage: [String: Data] = [:]
    var accessControls: [String: DeviceUnlockAccessControl] = [:]

    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws {
        storage[account] = derivedKey
        accessControls[account] = accessControl
    }

    func retrieve(account: String) throws -> Data? {
        storage[account]
    }

    func remove(account: String) throws {
        storage.removeValue(forKey: account)
        accessControls.removeValue(forKey: account)
    }

    func hasStoredKey(account: String) throws -> Bool {
        storage[account] != nil
    }
}
