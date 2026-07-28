import Foundation
import Security
import LocalAuthentication

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws
    func retrieve(account: String) throws -> Data?
    func remove(account: String) throws
    func hasStoredKey(account: String) throws -> Bool
}

enum BiometricKeyStoreError: Error {
    case accessControlCreationFailed
    case keychainWrite(OSStatus)
    case keychainRead(OSStatus)
}

final class BiometricKeyStore: BiometricKeyStoring {
    private let service: String

    init(service: String = "com.mypass.app.biometric") {
        self.service = service
    }

    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws {
        guard let secAccessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessControl.secAccessControlFlags,
            nil
        ) else {
            throw BiometricKeyStoreError.accessControlCreationFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = derivedKey
        attributes[kSecAttrAccessControl as String] = secAccessControl

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func retrieve(account: String) throws -> Data? {
        let context = LAContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
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
            kSecAttrAccount as String: account
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
