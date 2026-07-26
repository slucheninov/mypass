import Foundation
import MyPassKit

enum VaultBiometricEnrollment {
    static let account = "master"

    static func deriveTransformedKey(password: String, vaultData: Data) throws -> Data {
        try KdbxDatabase.deriveTransformedKey(fromVaultData: vaultData, password: password)
    }

    static func isEnrolled(biometricKeyStore: BiometricKeyStoring) -> Bool {
        (try? biometricKeyStore.hasStoredKey(account: account)) ?? false
    }

    static func enroll(
        password: String,
        vaultData: Data,
        biometricKeyStore: BiometricKeyStoring
    ) throws {
        let derivedKey = try deriveTransformedKey(password: password, vaultData: vaultData)
        try biometricKeyStore.store(derivedKey: derivedKey, account: account)
    }

    static func remove(biometricKeyStore: BiometricKeyStoring) throws {
        try biometricKeyStore.remove(account: account)
    }
}
