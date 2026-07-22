import Foundation
import Security
import LocalAuthentication

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String) throws
    func retrieve(account: String) throws -> Data?
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

    func store(derivedKey: Data, account: String) throws {
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
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
        attributes[kSecAttrAccessControl as String] = accessControl

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
}

final class FakeBiometricKeyStore: BiometricKeyStoring {
    private var storage: [String: Data] = [:]

    func store(derivedKey: Data, account: String) throws {
        storage[account] = derivedKey
    }

    func retrieve(account: String) throws -> Data? {
        storage[account]
    }
}
