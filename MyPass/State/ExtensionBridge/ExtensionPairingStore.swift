import CryptoKit
import Foundation
import Security

struct PairedBrowser: Codable, Equatable, Identifiable {
    let id: UUID
    let label: String
    let createdAt: Date
    let secretHash: String
}

protocol ExtensionPairingStoring: AnyObject {
    func list() -> [PairedBrowser]
    func add(_ browser: PairedBrowser) throws
    func remove(id: UUID) throws
    func containsSecret(matching secret: String) -> Bool
}

enum ExtensionPairingStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

private func sha256Hex(of secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8))
        .compactMap { String(format: "%02x", $0) }
        .joined()
}

private func hashesMatch(stored: String, computed: String) -> Bool {
    guard let a = stored.data(using: .utf8), let b = computed.data(using: .utf8), a.count == b.count else {
        return false
    }
    return a.withUnsafeBytes { aBytes in
        b.withUnsafeBytes { bBytes in
            timingsafe_bcmp(aBytes.baseAddress, bBytes.baseAddress, a.count) == 0
        }
    }
}

final class InMemoryExtensionPairingStore: ExtensionPairingStoring {
    private var browsers: [PairedBrowser] = []

    init() {}

    func list() -> [PairedBrowser] {
        browsers
    }

    func add(_ browser: PairedBrowser) throws {
        browsers.removeAll { $0.id == browser.id }
        browsers.append(browser)
    }

    func remove(id: UUID) throws {
        browsers.removeAll { $0.id == id }
    }

    func containsSecret(matching secret: String) -> Bool {
        let computed = sha256Hex(of: secret)
        return browsers.contains { hashesMatch(stored: $0.secretHash, computed: computed) }
    }
}

final class KeychainExtensionPairingStore: ExtensionPairingStoring {
    private let service = "com.mypass.extension.pairing"

    init() {}

    func list() -> [PairedBrowser] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(PairedBrowser.self, from: $0) }
    }

    func add(_ browser: PairedBrowser) throws {
        guard let data = try? JSONEncoder().encode(browser) else {
            throw ExtensionPairingStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: browser.id.uuidString
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ExtensionPairingStoreError.unexpectedStatus(status)
        }
    }

    func remove(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionPairingStoreError.unexpectedStatus(status)
        }
    }

    func containsSecret(matching secret: String) -> Bool {
        let computed = sha256Hex(of: secret)
        return list().contains { hashesMatch(stored: $0.secretHash, computed: computed) }
    }
}
