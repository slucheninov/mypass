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

    func testFakeRemoveClearsStoredKey() throws {
        let store = FakeBiometricKeyStore()
        let key = Data([0x01, 0x02, 0x03])
        try store.store(derivedKey: key, account: "master")
        XCTAssertTrue(try store.hasStoredKey(account: "master"))

        try store.remove(account: "master")

        XCTAssertFalse(try store.hasStoredKey(account: "master"))
        XCTAssertNil(try store.retrieve(account: "master"))
    }

    func testFakeHasStoredKeyReturnsFalseForMissingAccount() throws {
        let store = FakeBiometricKeyStore()
        XCTAssertFalse(try store.hasStoredKey(account: "missing"))
    }
}
