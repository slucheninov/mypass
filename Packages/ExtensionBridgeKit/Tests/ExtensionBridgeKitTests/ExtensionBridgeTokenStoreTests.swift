import XCTest
@testable import ExtensionBridgeKit

final class ExtensionBridgeTokenStoreTests: XCTestCase {

    // MARK: - InMemory (always run)

    func testInMemoryStoreStartsEmpty() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreSavesAndLoads() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let endpoint = ExtensionBridgeEndpoint(port: 54321, token: "abc123")
        try store.save(endpoint)
        XCTAssertEqual(try store.load(), endpoint)
    }

    func testInMemoryStoreClearRemovesEndpoint() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "x"))
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreOverwritesPreviousEndpoint() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "first"))
        try store.save(ExtensionBridgeEndpoint(port: 2, token: "second"))
        XCTAssertEqual(try store.load(), ExtensionBridgeEndpoint(port: 2, token: "second"))
    }

    // MARK: - generateToken (pure, always run)

    func testGenerateTokenProducesNonEmptyBase64() {
        let token = ExtensionBridgeTokenStore.generateToken()
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: token), "token must be valid base64")
    }

    func testGenerateTokenProducesDistinctValues() {
        let first = ExtensionBridgeTokenStore.generateToken()
        let second = ExtensionBridgeTokenStore.generateToken()
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Real Keychain (gated)

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    func testRealKeychainStoreSavesLoadsAndClears() throws {
        try requireKeychainTestsEnabled()
        let store = ExtensionBridgeTokenStore()
        try store.clear()
        XCTAssertNil(try store.load())

        let endpoint = ExtensionBridgeEndpoint(port: 49200, token: ExtensionBridgeTokenStore.generateToken())
        try store.save(endpoint)
        XCTAssertEqual(try store.load(), endpoint)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testRealKeychainStoreSaveOverwritesExistingEndpoint() throws {
        try requireKeychainTestsEnabled()
        let store = ExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "first"))
        try store.save(ExtensionBridgeEndpoint(port: 2, token: "second"))
        XCTAssertEqual(try store.load(), ExtensionBridgeEndpoint(port: 2, token: "second"))
        try store.clear()
    }
}
