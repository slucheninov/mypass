import XCTest
@testable import SyncKit

final class CredentialKeychainStoreTests: XCTestCase {
    // MARK: - InMemoryCredentialStore (always run — no external dependency)

    func testInMemoryStoreRoundTripsCredentials() throws {
        let store = InMemoryCredentialStore()
        let credentials = SFTPCredentials(username: "alice", privateKeyPEM: "-----BEGIN...-----", privateKeyPassphrase: "s3cret")

        XCTAssertNil(try store.loadCredentials(forHost: "sftp.example.com"))
        try store.store(credentials, forHost: "sftp.example.com")
        XCTAssertEqual(try store.loadCredentials(forHost: "sftp.example.com"), credentials)
    }

    func testInMemoryStoreKeepsHostsIndependent() throws {
        let store = InMemoryCredentialStore()
        let credentialsA = SFTPCredentials(username: "alice", privateKeyPEM: "key-a")
        let credentialsB = SFTPCredentials(username: "bob", privateKeyPEM: "key-b")

        try store.store(credentialsA, forHost: "host-a.example.com")
        try store.store(credentialsB, forHost: "host-b.example.com")

        XCTAssertEqual(try store.loadCredentials(forHost: "host-a.example.com"), credentialsA)
        XCTAssertEqual(try store.loadCredentials(forHost: "host-b.example.com"), credentialsB)
    }

    func testInMemoryStoreRemoveCredentials() throws {
        let store = InMemoryCredentialStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "key"), forHost: "sftp.example.com")
        try store.removeCredentials(forHost: "sftp.example.com")
        XCTAssertNil(try store.loadCredentials(forHost: "sftp.example.com"))
    }

    func testInMemoryStoreOverwritesExistingCredentialsForSameHost() throws {
        let store = InMemoryCredentialStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "old-key"), forHost: "sftp.example.com")
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "new-key"), forHost: "sftp.example.com")
        XCTAssertEqual(try store.loadCredentials(forHost: "sftp.example.com")?.privateKeyPEM, "new-key")
    }

    // MARK: - CredentialKeychainStore (real Keychain — gated, matches Phase 2's BiometricKeyStore convention)

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    private let realTestHost = "mypass-keychain-tests.invalid"

    override func tearDown() {
        try? CredentialKeychainStore().removeCredentials(forHost: realTestHost)
        super.tearDown()
    }

    func testRealKeychainStoreRoundTripsCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        let credentials = SFTPCredentials(username: "alice", privateKeyPEM: "-----BEGIN...-----", privateKeyPassphrase: "s3cret")

        try store.store(credentials, forHost: realTestHost)
        XCTAssertEqual(try store.loadCredentials(forHost: realTestHost), credentials)
    }

    func testRealKeychainStoreReturnsNilForUnknownHost() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        XCTAssertNil(try store.loadCredentials(forHost: "definitely-not-stored.invalid"))
    }

    func testRealKeychainStoreOverwriteReplacesPreviousCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "old-key"), forHost: realTestHost)
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "new-key"), forHost: realTestHost)
        XCTAssertEqual(try store.loadCredentials(forHost: realTestHost)?.privateKeyPEM, "new-key")
    }

    func testRealKeychainStoreRemoveCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "key"), forHost: realTestHost)
        try store.removeCredentials(forHost: realTestHost)
        XCTAssertNil(try store.loadCredentials(forHost: realTestHost))
    }
}
