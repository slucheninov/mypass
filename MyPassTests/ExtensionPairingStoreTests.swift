import XCTest
import CryptoKit
import ExtensionBridgeKit
@testable import MyPass

final class ExtensionPairingStoreTests: XCTestCase {

    func testInMemoryStoreStartsEmpty() {
        let store = InMemoryExtensionPairingStore()
        XCTAssertTrue(store.list().isEmpty)
    }

    func testInMemoryStoreAddListRemove() throws {
        let store = InMemoryExtensionPairingStore()
        let browser = PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: "abc")
        try store.add(browser)
        XCTAssertEqual(store.list(), [browser])
        try store.remove(id: browser.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testInMemoryContainsSecretUsesSHA256Hash() throws {
        let store = InMemoryExtensionPairingStore()
        let secret = "test-secret-b64"
        let hash = SHA256.hash(data: Data(secret.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        try store.add(PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: hash))
        XCTAssertTrue(store.containsSecret(matching: secret))
        XCTAssertFalse(store.containsSecret(matching: "wrong"))
        XCTAssertFalse(store.containsSecret(matching: ""))
    }

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    func testKeychainStoreAddListRemoveAndContainsSecret() throws {
        try requireKeychainTestsEnabled()
        let store = KeychainExtensionPairingStore()
        for existing in store.list() { try store.remove(id: existing.id) }

        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = SHA256.hash(data: Data(secret.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let browser = PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: hash)
        try store.add(browser)
        XCTAssertTrue(store.containsSecret(matching: secret))
        try store.remove(id: browser.id)
        XCTAssertFalse(store.containsSecret(matching: secret))
    }
}
