import XCTest
@testable import MyPass

final class BiometricKeyStoreTests: XCTestCase {
    func testFakeStoreRetrieveRoundTrips() throws {
        let store = FakeBiometricKeyStore()
        let key = Data([0xAA, 0xBB, 0xCC])
        try store.store(derivedKey: key, account: "default")
        XCTAssertEqual(try store.retrieve(account: "default"), key)
    }

    func testFakeStoreRetrieveReturnsNilForUnknownAccount() throws {
        let store = FakeBiometricKeyStore()
        XCTAssertNil(try store.retrieve(account: "missing"))
    }
}
