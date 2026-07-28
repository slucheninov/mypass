import Foundation

enum DeviceUnlockError: Error, Equatable {
    case invalidPasswordEncoding
    case notEnrolled
}

enum DeviceUnlockEnrollment {
    static let account = "deviceUnlockPassword"

    static func isEnrolled(biometricKeyStore: BiometricKeyStoring) -> Bool {
        (try? biometricKeyStore.hasStoredKey(account: account)) ?? false
    }

    static func enroll(
        password: String,
        accessControl: DeviceUnlockAccessControl,
        biometricKeyStore: BiometricKeyStoring
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw DeviceUnlockError.invalidPasswordEncoding
        }
        try biometricKeyStore.store(derivedKey: data, account: account, accessControl: accessControl)
    }

    static func retrievePassword(biometricKeyStore: BiometricKeyStoring) throws -> String {
        guard let data = try biometricKeyStore.retrieve(account: account),
              let password = String(data: data, encoding: .utf8) else {
            throw DeviceUnlockError.notEnrolled
        }
        return password
    }

    static func remove(biometricKeyStore: BiometricKeyStoring) throws {
        try biometricKeyStore.remove(account: account)
    }
}
