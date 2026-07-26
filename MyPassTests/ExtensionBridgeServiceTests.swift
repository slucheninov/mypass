import CryptoKit
import XCTest
import MyPassKit
import ExtensionBridgeKit
@testable import MyPass

final class ExtensionBridgeServiceTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var session: VaultSession!
    var service: ExtensionBridgeService!
    var authorizedPairingSecret: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassExtensionBridgeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let store = InMemoryExtensionPairingStore()
        let manager = ExtensionPairingManager(store: store)
        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = SHA256.hash(data: Data(secret.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        try store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        authorizedPairingSecret = secret
        service = ExtensionBridgeService(vaultSession: session, pairingManager: manager)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func addFixtureEntry(title: String, username: String, password: String, url: String) -> UUID {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = title
        entry.login = username
        entry.password = password
        entry.url = url
        session.mutate { db in
            db.rootGroup.entries.append(entry)
        }
        return entry.uuid
    }

    private func makeServiceWithPairing() -> (ExtensionBridgeService, InMemoryExtensionPairingStore, ExtensionPairingManager) {
        let store = InMemoryExtensionPairingStore()
        let manager = ExtensionPairingManager(store: store)
        let service = ExtensionBridgeService(vaultSession: session, pairingManager: manager)
        return (service, store, manager)
    }

    func testStartPairingReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let (service, _, _) = makeServiceWithPairing()
        XCTAssertEqual(service.handle(.startPairing(token: "t", browser: nil)), .locked)
    }

    func testStartPairingReturnsPairingStartedWhenUnlocked() {
        let (service, _, _) = makeServiceWithPairing()
        XCTAssertEqual(service.handle(.startPairing(token: "t", browser: "Google Chrome")), .pairingStarted)
    }

    func testGetCredentialsReturnsPairingRequiredWithoutSecret() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: nil))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testFillCredentialReturnsPairingRequiredWithoutSecret() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: nil))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testProposeSaveLoginReturnsPairingRequiredWithoutSecret() {
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.proposeSaveLogin(
            token: "t", url: "https://example.com/signup", username: "carol", password: "pw123", pairing: nil
        ))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testGetCredentialsReturnsListWhenAuthorized() throws {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, manager) = makeServiceWithPairing()
        let code = manager.startPairing(browser: nil)
        let secret = try XCTUnwrap(manager.completePairing(code: code))
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: secret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.count, 1)
    }

    func testCompletePairingReturnsPairedWithSecret() {
        let (service, _, manager) = makeServiceWithPairing()
        let code = manager.startPairing(browser: "Brave")
        guard case .paired(let secret) = service.handle(.completePairing(token: "t", code: code)) else {
            return XCTFail("expected paired response")
        }
        XCTAssertFalse(secret.isEmpty)
    }

    func testCompletePairingReturnsInvalidCodeOnMismatch() {
        let (service, _, manager) = makeServiceWithPairing()
        _ = manager.startPairing(browser: nil)
        XCTAssertEqual(service.handle(.completePairing(token: "t", code: "000000")), .error("invalid_code"))
    }

    func testGetCredentialsReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testGetCredentialsReturnsMatchingSummariesWithoutPasswords() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com/login", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "Example")
        XCTAssertEqual(summaries[0].username, "alice")
    }

    func testGetCredentialsExcludesNonMatchingDomain() {
        _ = addFixtureEntry(title: "Other", username: "bob", password: "pw", url: "https://other.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .credentialList([]))
    }

    func testFillCredentialReturnsPasswordForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .credential(username: "alice", password: "s3cret", totp: nil))
    }

    func testFillCredentialTouchesAccessForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        var touchedIDs: [UUID] = []
        service.onCredentialFilled = { touchedIDs.append($0) }
        _ = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(touchedIDs, [id])
    }

    /// TOTP-filling isn't implemented anywhere downstream: the base32 seed
    /// must never be echoed back into `.credential`'s totp field, even when
    /// the matched entry has one set — sending a long-lived secret to a web
    /// page's content-script world for a feature that doesn't exist is a
    /// pure liability.
    func testFillCredentialNeverReturnsTotpEvenWhenEntryHasOne() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        XCTAssertNil(totp)
    }

    func testFillCredentialReturnsErrorWhenDomainDoesNotMatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://not-example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testFillCredentialReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.fillCredential(token: "t", id: UUID().uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testProposeSaveLoginInvokesClosureAndReturnsAccepted() {
        var captured: (url: String, username: String, password: String)?
        service.onSaveProposal = { url, username, password in
            captured = (url, username, password)
        }
        let response = service.handle(.proposeSaveLogin(
            token: "t", url: "https://example.com/signup", username: "carol", password: "pw123", pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .saveProposalAccepted)
        XCTAssertEqual(captured?.url, "https://example.com/signup")
        XCTAssertEqual(captured?.username, "carol")
        XCTAssertEqual(captured?.password, "pw123")
    }

    func testProposeSaveLoginReturnsLockedAndDoesNotInvokeClosureWhenVaultIsLocked() {
        session.lock()
        var wasInvoked = false
        service.onSaveProposal = { _, _, _ in
            wasInvoked = true
        }
        let response = service.handle(.proposeSaveLogin(
            token: "t", url: "https://example.com/signup", username: "carol", password: "pw123", pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .locked)
        XCTAssertFalse(wasInvoked, "onSaveProposal must not fire while the vault is locked")
    }
}
