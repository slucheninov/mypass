import XCTest
import NIO
@testable import SyncKit

/// End-to-end tests against a REAL SFTP server, run only when explicitly
/// opted into via `MYPASS_SFTP_INTEGRATION_TESTS=1` — matches this plan's
/// existing convention (Task 9's `MYPASS_KEYCHAIN_TESTS=1`) for tests that
/// depend on an external resource rather than a pure in-process fake.
///
/// To exercise these locally:
///
/// ```sh
/// docker run -d --name mypass-sftp-test -p 2222:22 \
///   -v /tmp/citadel_smoke_key.pub:/home/testuser/.ssh/keys/id_ed25519.pub:ro \
///   -e SFTP_USERS=testuser::1001 \
///   atmoz/sftp
/// MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests
/// docker rm -f mypass-sftp-test
/// ```
///
/// `/tmp/citadel_smoke_key` is the real encrypted ed25519 keypair generated
/// in Task 8, Step 3.
final class SFTPBackendTests: XCTestCase {
    private func requireSFTPIntegrationTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_SFTP_INTEGRATION_TESTS"] == "1",
            "set MYPASS_SFTP_INTEGRATION_TESTS=1 (and run the atmoz/sftp Docker container described in this file's header comment) to run tests against a real SFTP server"
        )
    }

    private func makeConfiguration(remotePath: String) throws -> SFTPBackendConfiguration {
        let privateKeyPEM = try String(contentsOfFile: "/tmp/citadel_smoke_key", encoding: .utf8)
        return SFTPBackendConfiguration(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            remotePath: remotePath,
            privateKeyPEM: privateKeyPEM,
            privateKeyPassphrase: "correct-horse-battery-staple"
        )
    }

    func testExistsIsFalseForAPathThatHasNeverBeenWritten() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/does-not-exist-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }

    func testWriteThenReadRoundTripsBytesExactly() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/round-trip-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        let payload = Data("Hello, MyPass over SFTP!".utf8)
        try backend.write(payload)

        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testWriteTwiceReplacesThePreviousContent() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/overwrite-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        try backend.write(Data("first version".utf8))
        try backend.write(Data("second, longer version".utf8))

        XCTAssertEqual(try backend.read(), Data("second, longer version".utf8))
    }

    func testModificationDateAdvancesAcrossWrites() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/modtime-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        try backend.write(Data("v1".utf8))
        let firstModificationDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondModificationDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertGreaterThan(secondModificationDate, firstModificationDate)
    }

    func testSecondConnectionWithTheSameHostKeyStoreSucceedsAfterTrustOnFirstUse() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/tofu-\(UUID().uuidString).kdbx")
        let hostKeyStore = InMemoryTrustedHostKeyStore()

        let firstBackend = SFTPBackend(configuration: configuration, trustedHostKeyStore: hostKeyStore)
        try firstBackend.write(Data("first connection".utf8))
        XCTAssertNotNil(hostKeyStore.trustedKey(forHost: configuration.hostKeyIdentifier))

        // A second, independent backend reusing the SAME host key store must
        // succeed too — the host key trusted on the first connection must
        // match what the server presents again.
        let secondBackend = SFTPBackend(configuration: configuration, trustedHostKeyStore: hostKeyStore)
        XCTAssertEqual(try secondBackend.read(), Data("first connection".utf8))
    }
}
