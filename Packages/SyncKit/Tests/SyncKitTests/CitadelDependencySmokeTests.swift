import XCTest
import Crypto
import Citadel

/// Real, unencrypted-fixture-free smoke tests confirming Citadel is
/// correctly linked and its public API behaves as documented — not an
/// end-to-end SFTP test (that's Task 10's Docker-gated
/// `SFTPBackendTests`). The encrypted keypair used here is real, generated
/// via:
/// `ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"`
final class CitadelDependencySmokeTests: XCTestCase {
    private static let privateKeyPath = "/tmp/citadel_smoke_key"

    private let passphrase = "correct-horse-battery-staple"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.privateKeyPath),
            "Citadel smoke fixture missing. Regenerate with: ssh-keygen -t ed25519 -N \"correct-horse-battery-staple\" -f /tmp/citadel_smoke_key -C \"smoketest@mypass\""
        )
    }

    private func loadEncryptedPrivateKeyData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: Self.privateKeyPath))
    }

    func testCitadelTypesAreLinkedAndImportable() {
        // If SyncKit's Package.swift didn't correctly add Citadel as a
        // dependency + product, this file wouldn't even compile — this test
        // exists as an explicit, readable assertion of that fact.
        XCTAssertNotNil(SSHAlgorithms.self)
        XCTAssertNotNil(SSHReconnectMode.self)
    }

    func testDecryptingRealPrivateKeyWithCorrectPassphraseSucceeds() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: passphrase.data(using: .utf8)!)
        XCTAssertFalse(privateKey.publicKey.rawRepresentation.isEmpty)
    }

    func testWrongPassphraseThrowsInvalidOpenSSHKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        XCTAssertThrowsError(
            try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: "wrong-passphrase".data(using: .utf8)!)
        ) { error in
            // `InvalidOpenSSHKey`'s specific cases/`UnsupportedFeature` enum
            // are what Citadel actually throws for a malformed/undecryptable
            // key — this asserts the error TYPE, which is public.
            XCTAssertTrue(error is InvalidOpenSSHKey)
        }
    }

    func testMissingPassphraseThrowsForAnEncryptedKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        XCTAssertThrowsError(
            try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: nil)
        )
    }

    func testSSHAuthenticationMethodEd25519AcceptsTheDecryptedKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: passphrase.data(using: .utf8)!)
        // Constructing the authentication method must not throw — this is
        // exactly the call `SFTPBackend` (Task 10) makes with a decrypted key.
        _ = SSHAuthenticationMethod.ed25519(username: "smoketest", privateKey: privateKey)
    }
}
