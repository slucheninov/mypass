import XCTest
import MyPassKit
import ExtensionBridgeKit
@testable import MyPass

final class ExtensionBridgeServiceTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var session: VaultSession!
    var service: ExtensionBridgeService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassExtensionBridgeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        service = ExtensionBridgeService(vaultSession: session)
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

    func testGetCredentialsReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com"))
        XCTAssertEqual(response, .locked)
    }

    func testGetCredentialsReturnsMatchingSummariesWithoutPasswords() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com/login"))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "Example")
        XCTAssertEqual(summaries[0].username, "alice")
    }

    func testGetCredentialsExcludesNonMatchingDomain() {
        _ = addFixtureEntry(title: "Other", username: "bob", password: "pw", url: "https://other.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com"))
        XCTAssertEqual(response, .credentialList([]))
    }

    func testFillCredentialReturnsPasswordAndTotpForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com"))
        XCTAssertEqual(response, .credential(username: "alice", password: "s3cret", totp: "JBSWY3DP"))
    }

    func testFillCredentialReturnsErrorWhenDomainDoesNotMatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://not-example.com"))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testFillCredentialReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.fillCredential(token: "t", id: UUID().uuidString, url: "https://example.com"))
        XCTAssertEqual(response, .locked)
    }

    func testProposeSaveLoginInvokesClosureAndReturnsAccepted() {
        var captured: (url: String, username: String, password: String)?
        service.onSaveProposal = { url, username, password in
            captured = (url, username, password)
        }
        let response = service.handle(.proposeSaveLogin(
            token: "t", url: "https://example.com/signup", username: "carol", password: "pw123"
        ))
        XCTAssertEqual(response, .saveProposalAccepted)
        XCTAssertEqual(captured?.url, "https://example.com/signup")
        XCTAssertEqual(captured?.username, "carol")
        XCTAssertEqual(captured?.password, "pw123")
    }
}
