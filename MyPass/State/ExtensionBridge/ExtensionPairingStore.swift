import CryptoKit
import Foundation
import Security
import Combine

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

final class ExtensionPairingStoreModel: ObservableObject {
    let store: ExtensionPairingStoring

    init(store: ExtensionPairingStoring) {
        self.store = store
    }

    func refresh() -> [PairedBrowser] {
        store.list()
    }
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
    // App-only access group (distinct from ExtensionBridgeTokenStore's shared
    // "com.mypass.app.keychain") — ChromeHost must never read pairing secrets.
    private let accessGroup = "com.mypass.app.pairing"

    init() {}

    func list() -> [PairedBrowser] {
        // SecItemCopyMatching with kSecMatchLimitAll + kSecReturnData together
        // returns errSecParam (-50) for this generic-password query shape on
        // this sandboxed data-protection keychain, even though the exact same
        // query with kSecReturnAttributes succeeds. Work around it by listing
        // account identifiers first, then fetching each item's data with a
        // kSecMatchLimitOne query (the shape that is known to work, mirroring
        // ExtensionBridgeTokenStore.load()).
        let attributeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var attributeResult: AnyObject?
        let attributeStatus = SecItemCopyMatching(attributeQuery as CFDictionary, &attributeResult)
        if attributeStatus == errSecItemNotFound { return [] }
        guard attributeStatus == errSecSuccess, let attributeDicts = attributeResult as? [[String: Any]] else {
            return []
        }
        let accounts = attributeDicts.compactMap { $0[kSecAttrAccount as String] as? String }
        return accounts.compactMap { account in
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var dataResult: AnyObject?
            let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
            guard dataStatus == errSecSuccess, let data = dataResult as? Data else { return nil }
            return try? JSONDecoder().decode(PairedBrowser.self, from: data)
        }
    }

    func add(_ browser: PairedBrowser) throws {
        guard let data = try? JSONEncoder().encode(browser) else {
            throw ExtensionPairingStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: browser.id.uuidString,
            kSecAttrAccessGroup as String: accessGroup
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
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessGroup as String: accessGroup
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
