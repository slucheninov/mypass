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
        // Passkey create/get tests exercise the ceremony flow and assume the app-side
        // toggle is on unless a test explicitly overrides it (see the toggle-off tests
        // below) — matches the default `testGetPasskeyProxyStatus...` tests use.
        UserDefaults.standard.set(true, forKey: "passkeyProxyEnabled")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "passkeyProxyEnabled")
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

    /// Soft-deletes the fixture entry into the recycle bin, mirroring what the
    /// app's own delete flow does via `GroupTreeOperations.softDeleteEntry`.
    private func moveEntryToRecycleBin(_ id: UUID) {
        session.mutate { db in
            GroupTreeOperations.softDeleteEntry(
                withID: id, in: db.rootGroup,
                deletedObjects: &db.deletedObjects, recycleBinGroupUUID: &db.recycleBinGroupUUID
            )
        }
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

    func testFillCredentialReturnsLiveTotpWhenEntryHasSecret() throws {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        let code = try XCTUnwrap(totp, "expected a live TOTP code, got nil")
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber), "TOTP code must be all digits")
        XCTAssertNotEqual(code, "JBSWY3DPEHPK3PXP", "response must never echo the base32 seed")
    }

    func testFillCredentialReturnsNilTotpWhenEntryHasNoSecret() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        XCTAssertNil(totp)
    }

    func testGetCredentialsSetsHasTotpTrueWhenSecretPresent() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.first?.hasTotp, true)
    }

    func testGetCredentialsSetsHasTotpFalseWhenSecretAbsent() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.first?.hasTotp, false)
    }

    func testGetTotpReturnsLiveCodeForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .totp(let code) = response else {
            return XCTFail("expected totp response, got \(response)")
        }
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testGetTotpRejectsDomainMismatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://not-example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testGetTotpReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.getTotp(token: "t", id: UUID().uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testGetTotpReturnsPairingRequiredWithoutSecret() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: nil))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testGetTotpDoesNotTouchAccess() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        var touchedIDs: [UUID] = []
        service.onCredentialFilled = { touchedIDs.append($0) }
        _ = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertTrue(touchedIDs.isEmpty, "getTotp must not fire onCredentialFilled/touchAccess")
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

    // MARK: - requestUnlock

    /// Builds a service whose clock the test drives, sharing this case's session and a
    /// pairing manager authorising `authorizedPairingSecret`.
    private func makeServiceWithControlledClock(now: @escaping () -> Date) throws -> ExtensionBridgeService {
        let store = InMemoryExtensionPairingStore()
        let hash = SHA256.hash(data: Data(authorizedPairingSecret.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        try store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        return ExtensionBridgeService(
            vaultSession: session,
            pairingManager: ExtensionPairingManager(store: store),
            now: now
        )
    }

    func testRequestUnlockIsAnsweredWhileLockedAndInvokesCallback() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: authorizedPairingSecret))

        XCTAssertEqual(response, .unlockPresented)
        XCTAssertEqual(callbackCount, 1)
    }

    func testRequestUnlockWithoutPairingReturnsPairingRequiredAndDoesNotInvokeCallback() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: nil))

        XCTAssertEqual(response, .pairingRequired)
        XCTAssertEqual(callbackCount, 0)
    }

    func testRequestUnlockWithWrongPairingSecretReturnsPairingRequired() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: "not-the-secret"))

        XCTAssertEqual(response, .pairingRequired)
        XCTAssertEqual(callbackCount, 0)
    }

    func testRequestUnlockReturnsUnlockNotNeededWhenAlreadyUnlocked() {
        // setUpWithError leaves the session unlocked.
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: authorizedPairingSecret))

        XCTAssertEqual(response, .unlockNotNeeded)
        XCTAssertEqual(callbackCount, 0, "an unlocked vault must not raise the window")
    }

    func testRequestUnlockDebouncesRepeatsWithinTwoSeconds() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })
        var callbackCount = 0
        debounced.onUnlockRequested = { callbackCount += 1 }

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)
        clock = clock.addingTimeInterval(1.0)
        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)

        XCTAssertEqual(callbackCount, 1, "a repeat inside the window must not raise a second prompt")
    }

    func testRequestUnlockAcceptsAgainAfterTheDebounceWindow() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })
        var callbackCount = 0
        debounced.onUnlockRequested = { callbackCount += 1 }

        _ = debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret))
        clock = clock.addingTimeInterval(2.5)
        _ = debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret))

        XCTAssertEqual(callbackCount, 2)
    }

    /// The spec's load-bearing ordering: already-unlocked is checked BEFORE the debounce,
    /// so a click arriving right after a successful unlock tells the popup to re-query
    /// instead of being swallowed as a repeat.
    func testUnlockNotNeededWinsOverDebounce() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)

        try session.unlock(password: "correct-horse")
        clock = clock.addingTimeInterval(0.5) // still inside the debounce window

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockNotNeeded)
    }

    func testOtherRequestsStillReturnLockedWhenVaultIsLocked() {
        session.lock()
        XCTAssertEqual(
            service.handle(.getCredentials(token: "tok", url: "https://example.com", pairing: authorizedPairingSecret)),
            .locked
        )
        XCTAssertEqual(service.handle(.startPairing(token: "tok", browser: "Chrome")), .locked)
    }

    // MARK: - proposeSaveTotp

    func testProposeSaveTotpWithoutEntryIdInvokesClosureAndReturnsAccepted() {
        var captured: (url: String, otpauthOrSecret: String, entryId: UUID?)?
        service.onTotpSaveProposal = { url, otpauthOrSecret, entryId in
            captured = (url, otpauthOrSecret, entryId)
        }
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://example.com/setup", otpauthOrSecret: "otpauth://totp/Example:alice?secret=JBSWY3DP",
            entryId: nil, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .saveProposalAccepted)
        XCTAssertEqual(captured?.url, "https://example.com/setup")
        XCTAssertEqual(captured?.otpauthOrSecret, "otpauth://totp/Example:alice?secret=JBSWY3DP")
        XCTAssertNil(captured?.entryId)
    }

    func testProposeSaveTotpWithMatchingEntryIdInvokesClosureWithResolvedUUID() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        var captured: (url: String, otpauthOrSecret: String, entryId: UUID?)?
        service.onTotpSaveProposal = { url, otpauthOrSecret, entryId in
            captured = (url, otpauthOrSecret, entryId)
        }
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: id.uuidString, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .saveProposalAccepted)
        XCTAssertEqual(captured?.entryId, id)
    }

    func testProposeSaveTotpReturnsErrorWhenEntryIdDomainMismatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        var wasInvoked = false
        service.onTotpSaveProposal = { _, _, _ in wasInvoked = true }
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://not-example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: id.uuidString, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
        XCTAssertFalse(wasInvoked)
    }

    func testProposeSaveTotpReturnsPairingRequiredWithoutSecret() {
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://example.com/setup", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: nil
        ))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testProposeSaveTotpReturnsLockedAndDoesNotInvokeClosureWhenVaultIsLocked() {
        session.lock()
        var wasInvoked = false
        service.onTotpSaveProposal = { _, _, _ in wasInvoked = true }
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://example.com/setup", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .locked)
        XCTAssertFalse(wasInvoked)
    }

    // MARK: - Recycle bin exclusion

    func testGetCredentialsExcludesRecycleBinEntries() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        moveEntryToRecycleBin(id)
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .credentialList([]))
    }

    func testFillCredentialReturnsErrorForRecycleBinEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        moveEntryToRecycleBin(id)
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testGetTotpReturnsErrorForRecycleBinEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        moveEntryToRecycleBin(id)
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testProposeSaveTotpReturnsErrorForRecycleBinEntryId() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        moveEntryToRecycleBin(id)
        var wasInvoked = false
        service.onTotpSaveProposal = { _, _, _ in wasInvoked = true }
        let response = service.handle(.proposeSaveTotp(
            token: "t", url: "https://example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: id.uuidString, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
        XCTAssertFalse(wasInvoked)
    }

    // MARK: - Passkeys

    /// `origin` defaults to the same `https://example.com` the existing tests already pass
    /// as `originUrl`, so call sites that don't care about origin validation keep passing
    /// unchanged. Call sites that vary `originUrl` (localhost fixtures, the no-match fixture)
    /// pass a matching `origin` explicitly, exactly like `background.js` stamps the two
    /// fields from the same source and the app now checks they agree.
    private func createFixtureRequestJSON(rpId: String = "example.com", origin: String = "https://example.com") -> String {
        """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1, 2, 3, 4])))",
          "rp": { "id": "\(rpId)", "name": "Example" },
          "user": { "id": "\(PasskeyBase64URL.encode(Data([9, 9])))", "name": "alice", "displayName": "Alice" },
          "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
          "attestation": "none",
          "extensions": { "remoteDesktopClientOverride": { "origin": "\(origin)" } }
        }
        """
    }

    private func getFixtureRequestJSON(
        rpId: String = "example.com", allowCredentials: [Data] = [], origin: String = "https://example.com"
    ) -> String {
        let allow = allowCredentials
            .map { "{ \"type\": \"public-key\", \"id\": \"\(PasskeyBase64URL.encode($0))\" }" }
            .joined(separator: ", ")
        return """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([4, 4, 4])))",
          "rpId": "\(rpId)",
          "allowCredentials": [\(allow)],
          "extensions": { "remoteDesktopClientOverride": { "origin": "\(origin)" } }
        }
        """
    }

    private func attachPasskey(to id: UUID, rpId: String = "example.com", pem: String = "pem", credentialId: Data? = Data([1, 2, 3])) {
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) else { return }
            db.rootGroup.entries[index].passkeyRelyingParty = rpId
            db.rootGroup.entries[index].passkeyPrivateKeyPEM = pem
            db.rootGroup.entries[index].passkeyCredentialId = credentialId
        }
    }

    func testGetPasskeyProxyStatusReportsUnlockedAndAttachAllowed() {
        defer { UserDefaults.standard.removeObject(forKey: "passkeyProxyEnabled") }
        UserDefaults.standard.set(true, forKey: "passkeyProxyEnabled")
        let response = service.handle(.getPasskeyProxyStatus(token: "t", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: true, enabled: true))
    }

    /// Turning the feature off in Settings has to actually stop the extension attaching.
    /// There is no push channel, so `attachAllowed` is the only way the app can say no.
    func testGetPasskeyProxyStatusDisallowsAttachWhenTheAppSideToggleIsOff() {
        defer { UserDefaults.standard.removeObject(forKey: "passkeyProxyEnabled") }
        UserDefaults.standard.set(false, forKey: "passkeyProxyEnabled")
        let response = service.handle(.getPasskeyProxyStatus(token: "t", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: false, enabled: false))
    }

    /// The one message that must answer past the blanket locked gate — otherwise the
    /// extension can never learn *why* it may not attach.
    func testGetPasskeyProxyStatusReportsLockedWithoutReturningGenericLockedResponse() {
        defer { UserDefaults.standard.removeObject(forKey: "passkeyProxyEnabled") }
        UserDefaults.standard.set(true, forKey: "passkeyProxyEnabled")
        session.lock()
        let response = service.handle(.getPasskeyProxyStatus(token: "t", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .passkeyProxyStatus(unlocked: false, paired: true, attachAllowed: false, enabled: true))
    }

    func testGetPasskeyProxyStatusReturnsPairingRequiredWithoutSecret() {
        let (unpairedService, _, _) = makeServiceWithPairing()
        XCTAssertEqual(unpairedService.handle(.getPasskeyProxyStatus(token: "t", pairing: nil)), .pairingRequired)
    }

    func testSetPasskeyProxyEnabledPersistsAndReturnsEnabled() {
        defer { UserDefaults.standard.removeObject(forKey: "passkeyProxyEnabled") }
        // setUpWithError defaults this to true for the passkey-create/get tests; set it false
        // first so this test actually exercises the false -> true persistence, rather than
        // passing merely because the default already happened to be true.
        UserDefaults.standard.set(false, forKey: "passkeyProxyEnabled")
        let response = service.handle(.setPasskeyProxyEnabled(token: "t", enabled: true, pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .passkeyProxyEnabled(enabled: true))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "passkeyProxyEnabled"))
    }

    func testSetPasskeyProxyEnabledRequiresPairing() {
        let (unpairedService, _, _) = makeServiceWithPairing()
        XCTAssertEqual(
            unpairedService.handle(.setPasskeyProxyEnabled(token: "t", enabled: true, pairing: nil)),
            .pairingRequired
        )
    }

    func testGetCredentialsSetsHasPasskeyTrueWhenPrivateKeyPresent() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else { return XCTFail("expected credentialList") }
        XCTAssertEqual(summaries.first?.hasPasskey, true)
    }

    func testPasskeyCreateReturnsPendingWithZeroMatches() {
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 1, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(let requestId, let rpId, let rpName, let matches) = response else {
            return XCTFail("expected passkeyCreatePending, got \(response)")
        }
        XCTAssertEqual(requestId, 1)
        XCTAssertEqual(rpId, "example.com")
        XCTAssertEqual(rpName, "Example")
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Passkey origin validation

    /// Check 1 alone: the extension's own payload claims a different origin than the
    /// message envelope's `originUrl`. A single compromised field is exactly what Check 1
    /// exists to catch — see `PasskeyCeremony.validateOrigin`.
    func testPasskeyCreateRejectsWhenOriginUrlDisagreesWithPayloadOrigin() {
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 50, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://attacker.example", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 50)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "SecurityError")
    }

    /// Fail closed, matching `background.js`'s own `originFromRequestDetails()`: a payload
    /// that never carries `extensions.remoteDesktopClientOverride` must not be trusted just
    /// because `originUrl` happens to look plausible.
    func testPasskeyCreateRejectsWhenPayloadHasNoRemoteDesktopClientOverride() {
        let json = """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1, 2, 3, 4])))",
          "rp": { "id": "example.com", "name": "Example" },
          "user": { "id": "\(PasskeyBase64URL.encode(Data([9, 9])))", "name": "alice", "displayName": "Alice" },
          "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
          "attestation": "none"
        }
        """
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 51, requestDetailsJson: json,
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 51)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "SecurityError")
    }

    /// Check 2: an unrelated rpId must not be authorized just because Check 1 passed.
    func testPasskeyCreateRejectsRpIdNotAuthorizedForOrigin() {
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 52, requestDetailsJson: createFixtureRequestJSON(rpId: "evil.com"),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 52)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "SecurityError")
    }

    /// Check 2's Public Suffix List half: an rpId must not climb past the registrable
    /// domain — "co.uk" is a public suffix, not a domain "evil.co.uk" can claim.
    func testPasskeyCreateRejectsRpIdClimbingPastPublicSuffix() {
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 53,
            requestDetailsJson: createFixtureRequestJSON(rpId: "co.uk", origin: "https://evil.co.uk"),
            originUrl: "https://evil.co.uk", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 53)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "SecurityError")
    }

    /// A subdomain origin authorizing its parent registrable domain's rpId is the normal,
    /// legitimate WebAuthn case and must still work once origin validation is in place.
    func testPasskeyCreateAllowsRpIdOnParentRegistrableDomain() {
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 54,
            requestDetailsJson: createFixtureRequestJSON(rpId: "example.com", origin: "https://login.example.com"),
            originUrl: "https://login.example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending = response else {
            return XCTFail("expected passkeyCreatePending, got \(response)")
        }
    }

    func testPasskeyCreateReturnsUnsupportedAlgorithmError() {
        let json = """
        { "challenge": "AAEC", "rp": { "id": "example.com" }, "user": { "id": "AAEC", "name": "a" }, \
        "pubKeyCredParams": [{ "type": "public-key", "alg": -257 }] }
        """
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 2, requestDetailsJson: json, originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotSupportedError")
    }

    func testPasskeyCreateDoesNotWriteToTheVault() {
        let before = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).count
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 20, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).count, before,
                       "phase 1 must never mutate the vault — only the confirm phase may")
    }

    func testPasskeyCreateThenConfirmWritesEntryAndReturnsResponseJson() {
        let prepareResponse = service.handle(.passkeyCreate(
            token: "t", requestId: 3, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending = prepareResponse else { return XCTFail("expected pending") }

        let confirmResponse = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 3, entryId: nil, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = confirmResponse else {
            return XCTFail("expected passkeyCreateComplete, got \(confirmResponse)")
        }
        XCTAssertEqual(requestId, 3)
        XCTAssertNil(error)
        XCTAssertNotNil(responseJson)

        let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
        XCTAssertTrue(entries.contains { $0.passkeyRelyingParty == "example.com" && $0.passkeyPrivateKeyPEM?.isEmpty == false })

        // The creation date is stamped by the ceremony, not derived from the entry's own
        // timestamps — a passkey added to a long-existing entry must date from today.
        let created = entries.first { $0.passkeyRelyingParty == "example.com" }?.passkeyCreatedAt
        XCTAssertNotNil(created)
        XCTAssertLessThan(abs(created!.timeIntervalSinceNow), 60)
    }

    func testPasskeyCreateConfirmRequiresReplaceFlagWhenEntryAlreadyHasPasskey() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id, pem: "existing-pem")
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 4, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 4, entryId: id.uuidString, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "InvalidStateError")

        let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
        XCTAssertEqual(entries.first { $0.uuid == id }?.passkeyPrivateKeyPEM, "existing-pem", "must not overwrite without replace: true")
    }

    func testPasskeyCreateConfirmOverwritesWhenReplaceIsTrue() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id, pem: "existing-pem")
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 21, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 21, entryId: id.uuidString, replace: true, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(error)
        XCTAssertNotNil(responseJson)

        let entry = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).first { $0.uuid == id }
        XCTAssertNotEqual(entry?.passkeyPrivateKeyPEM, "existing-pem")
        XCTAssertTrue(entry?.passkeyPrivateKeyPEM?.contains("PRIVATE KEY") == true)
    }

    /// Regression guard: the confirm write must locate the target anywhere in the group
    /// tree. Looking only at `rootGroup.entries` would report success while writing nothing.
    func testPasskeyCreateConfirmWritesToAnEntryInASubgroup() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            let subgroup = GroupTreeOperations.addGroup(named: "Work", emoji: nil, to: db.rootGroup)
            _ = GroupTreeOperations.moveEntry(withID: id, to: subgroup.uuid, in: db.rootGroup)
        }
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 26, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 26, entryId: id.uuidString, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(error)
        XCTAssertNotNil(responseJson)

        let entry = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).first { $0.uuid == id }
        XCTAssertEqual(entry?.passkeyRelyingParty, "example.com")
        XCTAssertTrue(entry?.passkeyPrivateKeyPEM?.contains("PRIVATE KEY") == true)
    }

    func testPasskeyCreateReturnsLockedAndDoesNotWriteWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 5, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .locked)
    }

    func testPasskeyCreateRequiresPairing() {
        let (unpairedService, _, _) = makeServiceWithPairing()
        let response = unpairedService.handle(.passkeyCreate(
            token: "t", requestId: 22, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: nil
        ))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testPasskeyCreateRefusesWhenAppSideToggleIsOff() {
        UserDefaults.standard.set(false, forKey: "passkeyProxyEnabled")
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 42, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyCreateComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 42)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError")
        XCTAssertEqual(error?.message, "MyPass passkeys are turned off in Settings")
    }

    func testPasskeyGetReturnsPendingForMatchingRp() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 6, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetPending(_, let rpId, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertEqual(rpId, "example.com")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.hasPasskey, true)
    }

    func testPasskeyGetFiltersByAllowCredentials() {
        let matching = addFixtureEntry(title: "Match", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: matching, credentialId: Data([7, 7, 7]))
        let other = addFixtureEntry(title: "Other", username: "bob", password: "s3cret", url: "https://example.com")
        attachPasskey(to: other, credentialId: Data([8, 8, 8]))

        let response = service.handle(.passkeyGet(
            token: "t", requestId: 23, requestDetailsJson: getFixtureRequestJSON(allowCredentials: [Data([7, 7, 7])]),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetPending(_, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertEqual(matches.map(\.title), ["Match"])
    }

    func testPasskeyGetRefusesWhenAppSideToggleIsOff() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        UserDefaults.standard.set(false, forKey: "passkeyProxyEnabled")
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 43, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyGetComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 43)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError")
        XCTAssertEqual(error?.message, "MyPass passkeys are turned off in Settings")
    }

    func testPasskeyGetReturnsNotAllowedErrorWhenNoMatch() {
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 7, requestDetailsJson: getFixtureRequestJSON(rpId: "no-such-site.com", origin: "https://no-such-site.com"),
            originUrl: "https://no-such-site.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete, got \(response)") }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError")
    }

    /// Same origin-mismatch gate as create, exercised on the get/assertion path.
    func testPasskeyGetRejectsWhenOriginUrlDisagreesWithPayloadOrigin() {
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 60, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://attacker.example", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(let requestId, let responseJson, let error) = response else {
            return XCTFail("expected passkeyGetComplete with error, got \(response)")
        }
        XCTAssertEqual(requestId, 60)
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "SecurityError")
    }

    /// A subdomain origin authorizing its parent registrable domain's rpId must still reach
    /// the normal candidate lookup rather than being rejected outright by origin validation.
    func testPasskeyGetAllowsRpIdOnParentRegistrableDomain() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://login.example.com")
        attachPasskey(to: id, rpId: "example.com")
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 61,
            requestDetailsJson: getFixtureRequestJSON(rpId: "example.com", origin: "https://login.example.com"),
            originUrl: "https://login.example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetPending(_, let rpId, let matches) = response else {
            return XCTFail("expected pending, got \(response)")
        }
        XCTAssertEqual(rpId, "example.com")
        XCTAssertEqual(matches.count, 1)
    }

    /// Same choke-point rule the other four bridge requests already follow: a
    /// soft-deleted entry is invisible to the extension, passkeys included.
    func testPasskeyGetIgnoresRecycleBinEntries() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        moveEntryToRecycleBin(id)
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 24, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(_, _, let error) = response else { return XCTFail("expected complete, got \(response)") }
        XCTAssertEqual(error?.name, "NotAllowedError")
    }

    func testPasskeyCreateIgnoresRecycleBinEntriesWhenListingMatches() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        moveEntryToRecycleBin(id)
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 25, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertTrue(matches.isEmpty)
    }

    /// Gate 6 regression: two plain Login entries already exist for the page host but
    /// neither has a passkey yet. Both must surface as picker candidates instead of the
    /// popup falling back to the generic "create a brand-new entry" panel.
    func testPasskeyCreateOffersDomainMatchedLoginEntriesWithoutExistingPasskeys() {
        let first = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")
        let second = addFixtureEntry(title: "Site Backup Login", username: "alice-2", password: "s3cret2", url: "http://localhost:8765")
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 30, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map { $0.id }), Set([first, second].map(\.uuidString)))
        XCTAssertTrue(matches.allSatisfy { $0.hasPasskey == false })
    }

    /// Single domain-matched Login entry with no passkey yet: the picker should collapse
    /// to exactly one candidate, matching the spec's "1 match" popup path.
    func testPasskeyCreateOffersSingleDomainMatchedLoginEntry() {
        let id = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 31, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.id, id.uuidString)
        XCTAssertEqual(matches.first?.hasPasskey, false)
    }

    /// An entry already carrying a passkey for the rpId — but saved under a different (or
    /// empty) URL, so it does not domain-match the current origin — must still be offered
    /// (so "replace passkey" stays reachable), unioned with the domain-matched Login and
    /// without appearing twice when an entry satisfies both predicates.
    func testPasskeyCreateUnionsRpIdPasskeyEntriesWithDomainMatchesWithoutDuplicates() {
        let passkeyOnly = addFixtureEntry(title: "Old Passkey Entry", username: "carol", password: "s3cret", url: "")
        attachPasskey(to: passkeyOnly, rpId: "localhost")
        let loginOnly = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")

        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 32, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map { $0.id }), Set([passkeyOnly, loginOnly].map(\.uuidString)))
        XCTAssertEqual(matches.first { $0.id == passkeyOnly.uuidString }?.hasPasskey, true)
        XCTAssertEqual(matches.first { $0.id == loginOnly.uuidString }?.hasPasskey, false)

        // Now attach a passkey for the same rpId on the domain-matched entry too, so it
        // satisfies both predicates — it must still appear exactly once.
        attachPasskey(to: loginOnly, rpId: "localhost")
        let secondResponse = service.handle(.passkeyCreate(
            token: "t", requestId: 33, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let secondMatches) = secondResponse else {
            return XCTFail("expected pending, got \(secondResponse)")
        }
        XCTAssertEqual(secondMatches.count, 2, "an entry satisfying both predicates must not be listed twice")
    }

    /// Recycle-bin exclusion must also hold for the domain-matched half of the union, not
    /// just the passkey-only half already covered by `testPasskeyCreateIgnoresRecycleBinEntriesWhenListingMatches`.
    func testPasskeyCreateIgnoresRecycleBinEntriesAmongDomainMatches() {
        let id = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")
        moveEntryToRecycleBin(id)
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 34, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertTrue(matches.isEmpty)
    }

    /// `passkeyCreateConfirm` must write to whichever of several domain-matched entries the
    /// user picked, not just "the first one found" — regression guard for choosing the
    /// second of two candidates from the new union-based picker.
    func testPasskeyCreateConfirmWritesToTheChosenEntryAmongMultipleDomainMatches() {
        _ = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")
        let second = addFixtureEntry(title: "Site Backup Login", username: "alice-2", password: "s3cret2", url: "http://localhost:8765")

        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 35, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 35, entryId: second.uuidString, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(error)
        XCTAssertNotNil(responseJson)

        let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
        let updated = entries.first { $0.uuid == second }
        XCTAssertEqual(updated?.passkeyRelyingParty, "localhost")
        XCTAssertTrue(updated?.passkeyPrivateKeyPEM?.contains("PRIVATE KEY") == true)
        XCTAssertEqual(entries.count, 2, "confirming against an existing entry must not also create a new one")
    }

    /// Regression guard: `passkeyCreateConfirm` must reject an `entryId` that was never a
    /// candidate the popup was shown for this ceremony — otherwise a stale UI, a forged
    /// message, or a race with a changed candidate set could attach a passkey to an
    /// unrelated entry, the same domain-scoping `fillCredential`/`getTotp`/`proposeSaveTotp`
    /// already enforce via `matchingEntries(forURL:)`.
    func testPasskeyCreateConfirmRejectsEntryIdOutsideTheCandidateSet() {
        let hostEntry = addFixtureEntry(title: "Site Login", username: "alice", password: "s3cret", url: "http://localhost:8765")
        let otherHostEntry = addFixtureEntry(title: "Other Site", username: "bob", password: "s3cret2", url: "https://other-site.example")

        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 36, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 36, entryId: otherHostEntry.uuidString, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError")

        let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
        XCTAssertTrue(entries.allSatisfy { $0.passkeyPrivateKeyPEM?.isEmpty != false }, "no entry must have gained a passkey")
        XCTAssertEqual(entries.count, 2, "an out-of-candidate-set entryId must not fall back to creating a new entry either")

        // A confirm carrying the pending request's own requestId again must fail, not
        // resurrect it — the pending record was cleared on the rejected attempt above.
        let retry = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 36, entryId: hostEntry.uuidString, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, _, let retryError) = retry else { return XCTFail("expected complete") }
        XCTAssertEqual(retryError?.name, "NotAllowedError", "the pending record must be cleared after a rejected entryId")
    }

    func testPasskeyGetThenApproveSignsAssertion() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 8, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        _ = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 8, entryId: id.uuidString, replace: false, pairing: authorizedPairingSecret
        ))

        let getPrepare = service.handle(.passkeyGet(
            token: "t", requestId: 9, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetPending = getPrepare else { return XCTFail("expected pending, got \(getPrepare)") }

        let approveResponse = service.handle(.passkeyGetApprove(
            token: "t", requestId: 9, entryId: id.uuidString, pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(_, let responseJson, let error) = approveResponse else {
            return XCTFail("expected complete, got \(approveResponse)")
        }
        XCTAssertNil(error)
        XCTAssertNotNil(responseJson)
    }

    func testPasskeyGetApproveWithoutPendingRequestFails() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        let response = service.handle(.passkeyGetApprove(
            token: "t", requestId: 999, entryId: id.uuidString, pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError")
    }

    func testPasskeyCancelClearsPendingStateForBothCreateAndGet() {
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 10, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        let cancelResponse = service.handle(.passkeyCancel(token: "t", requestId: 10, pairing: authorizedPairingSecret))
        XCTAssertEqual(cancelResponse, .passkeyCancelled(requestId: 10))

        let confirmAfterCancel = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 10, entryId: nil, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJson, let error) = confirmAfterCancel else { return XCTFail("expected complete") }
        XCTAssertNil(responseJson)
        XCTAssertEqual(error?.name, "NotAllowedError", "confirming a cancelled request must fail, not silently succeed")
    }

    /// Locking the vault must invalidate any ceremony that was mid-flight, so a
    /// confirm arriving after a re-unlock cannot resurrect it.
    func testLockingTheVaultDropsPendingCeremonies() throws {
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 11, requestDetailsJson: createFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        session.lock()
        try session.unlock(password: "correct-horse")

        let response = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 11, entryId: nil, replace: false, pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, _, let error) = response else { return XCTFail("expected complete") }
        XCTAssertEqual(error?.name, "NotAllowedError")
    }

    // MARK: - Auto-lock activity notification

    /// A request must not count as "the user did something" unless it was actually
    /// served — an unpaired client that can read nothing must not keep the vault awake
    /// just by being gesture-shaped.
    func testUnpairedFillCredentialDoesNotNotifyAutoLockActivityRecorder() {
        let recorder = SpyAutoLockActivityRecorder()
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let notifying = ExtensionBridgeService(
            vaultSession: session, pairingManager: ExtensionPairingManager(store: InMemoryExtensionPairingStore()),
            autoLockActivityRecorder: recorder
        )

        let response = notifying.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: nil))

        XCTAssertEqual(response, .pairingRequired)
        XCTAssertEqual(recorder.recordActivityCallCount, 0, "an unpaired request was refused, not served — must not reset the idle timer")
    }

    func testPairedAndServedFillCredentialNotifiesAutoLockActivityRecorder() {
        let recorder = SpyAutoLockActivityRecorder()
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let store = InMemoryExtensionPairingStore()
        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = SHA256.hash(data: Data(secret.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        try! store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        let notifying = ExtensionBridgeService(
            vaultSession: session, pairingManager: ExtensionPairingManager(store: store),
            autoLockActivityRecorder: recorder
        )

        let response = notifying.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: secret))

        guard case .credential = response else { return XCTFail("expected the request to actually be served") }
        XCTAssertEqual(recorder.recordActivityCallCount, 1, "a paired, served fillCredential is a deliberate user action and must reset the idle timer")
    }

    func testGetPasskeyProxyStatusDoesNotNotifyAutoLockActivityRecorder() {
        let recorder = SpyAutoLockActivityRecorder()
        let notifying = ExtensionBridgeService(
            vaultSession: session, pairingManager: ExtensionPairingManager(store: InMemoryExtensionPairingStore()),
            autoLockActivityRecorder: recorder
        )

        _ = notifying.handle(.getPasskeyProxyStatus(token: "t", pairing: nil))

        XCTAssertEqual(recorder.recordActivityCallCount, 0, "background status polling must not reset the idle timer")
    }
}

final class SpyAutoLockActivityRecorder: AutoLockActivityRecording {
    private(set) var recordActivityCallCount = 0
    func recordActivity() { recordActivityCallCount += 1 }
}
