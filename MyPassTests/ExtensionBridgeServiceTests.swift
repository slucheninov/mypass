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

    private func addAddressFixture() -> KdbxEntry {
        let entry = AddressEntryEditing.savedEntry(existing: nil, title: "Home", address: ExtensionAddress(
            fullName: "Ada Example", addressLine1: "12 Example Street", city: "Warsaw", countryCode: "PL", countryName: "Poland"
        ), favorite: false, notes: "")
        session.mutate { $0.rootGroup.entries.append(entry) }
        return entry
    }

    func testOnlyServedAddressFillResetsIdleTimer() throws {
        let entry = addAddressFixture()
        let recorder = SpyAutoLockActivityRecorder()
        let manager = ExtensionPairingManager(store: InMemoryExtensionPairingStore())
        let pairing = try XCTUnwrap(manager.completePairing(code: manager.startPairing(browser: "Address test")))
        let notifying = ExtensionBridgeService(vaultSession: session, pairingManager: manager, autoLockActivityRecorder: recorder)
        XCTAssertEqual(notifying.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: nil)), .pairingRequired)
        XCTAssertEqual(recorder.recordActivityCallCount, 0)
        XCTAssertEqual(notifying.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: pairing)), .address(entry.address))
        XCTAssertEqual(recorder.recordActivityCallCount, 1)
        _ = notifying.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "file:///tmp/form.html", pairing: pairing))
        XCTAssertEqual(recorder.recordActivityCallCount, 1)
    }

    func testAddressFillRequiresPairingAndUnlockedVault() {
        let entry = addAddressFixture()
        let unpaired = service.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: nil))
        XCTAssertEqual(unpaired, .pairingRequired)
        session.lock()
        XCTAssertEqual(service.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: authorizedPairingSecret)), .locked)
    }

    func testAddressFillIsGlobalButRejectsNonWebsiteURLsWrongTypesAndDeletedEntries() {
        let entry = addAddressFixture()
        for url in ["https://shop.example/checkout", "https://another.example/account"] {
            XCTAssertEqual(service.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: url, pairing: authorizedPairingSecret)), .address(entry.address))
        }
        for url in ["file:///tmp/form.html", "javascript:alert(1)", "chrome://settings", "https:///", "https://user:password@shop.example", "shop.example"] {
            guard case .error = service.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: url, pairing: authorizedPairingSecret)) else {
                return XCTFail("Accepted invalid destination: \(url)")
            }
        }
        let loginID = addFixtureEntry(title: "Login", username: "user", password: "secret", url: "https://shop.example")
        XCTAssertEqual(service.handle(.fillAddress(token: "t", id: loginID.uuidString, url: "https://shop.example", pairing: authorizedPairingSecret)), .error("Address not found"))
        moveEntryToRecycleBin(entry.uuid)
        XCTAssertEqual(service.handle(.fillAddress(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: authorizedPairingSecret)), .error("Address not found"))
    }

    func testAddressBrowseIsSummaryOnlyAndNeverAWebsiteCredential() {
        var entry = addAddressFixture()
        entry.url = "https://shop.example"
        session.mutate { EntryPersistence.replaceEntry(entry, in: $0.rootGroup) }
        guard case .credentialList(let rows) = service.handle(.listEntries(token: "t", category: "addresses", pairing: authorizedPairingSecret)) else {
            return XCTFail("Expected address list")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.entryType, "Address")
        XCTAssertEqual(rows.first?.username, "Ada Example")
        XCTAssertEqual(service.handle(.getCredentials(token: "t", url: "https://shop.example", pairing: authorizedPairingSecret)), .credentialList([]))
        XCTAssertEqual(service.handle(.fillCredential(token: "t", id: entry.uuid.uuidString, url: "https://shop.example", pairing: authorizedPairingSecret)), .error("entry not found or domain mismatch"))
        moveEntryToRecycleBin(entry.uuid)
        XCTAssertEqual(service.handle(.listEntries(token: "t", category: "addresses", pairing: authorizedPairingSecret)), .credentialList([]))
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

    func testGetFavoritesReturnsOnlyFavoritesWithTheirUrl() {
        let plain = addFixtureEntry(title: "Plain", username: "pat", password: "pw", url: "https://plain.example")
        let zebra = addFixtureEntry(title: "zebra", username: "z", password: "pw", url: "https://zebra.example")
        let alpha = addFixtureEntry(title: "Alpha", username: "a", password: "pw", url: "https://alpha.example")
        let binned = addFixtureEntry(title: "Binned", username: "b", password: "pw", url: "https://binned.example")
        let never = addFixtureEntry(title: "Never", username: "n", password: "pw", url: "https://never.example")
        session.mutate { db in
            for id in [zebra, alpha, binned, never] {
                guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) else { continue }
                db.rootGroup.entries[index].isFavorite = true
            }
            guard let neverIndex = db.rootGroup.entries.firstIndex(where: { $0.uuid == never }) else { return }
            db.rootGroup.entries[neverIndex].uriMatchMode = .never
        }
        moveEntryToRecycleBin(binned)

        let response = service.handle(.getFavorites(token: "t", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.map(\.title), ["Alpha", "zebra"])
        XCTAssertEqual(summaries.map(\.username), ["a", "z"])
        XCTAssertEqual(summaries.map(\.url), ["https://alpha.example", "https://zebra.example"])
        XCTAssertFalse(summaries.contains { $0.id == plain.uuidString })
    }

    func testGetFavoritesReturnsPairingRequiredWithoutSecret() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        XCTAssertEqual(service.handle(.getFavorites(token: "t", pairing: nil)), .pairingRequired)
    }

    func testGetFavoritesReturnsLockedWhenVaultIsLocked() {
        session.lock()
        XCTAssertEqual(
            service.handle(.getFavorites(token: "t", pairing: authorizedPairingSecret)),
            .locked
        )
    }

    func testListEntriesSplitsCategoriesAndSearchFindsTheLogin() {
        let login = addFixtureEntry(title: "Alpha Mail", username: "ada", password: "pw", url: "https://alpha.example")
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == login }) else { return }
            db.rootGroup.entries[index].isFavorite = true
        }
        _ = addFixtureEntry(title: "Plain", username: "pat", password: "pw", url: "https://plain.example")
        let now = Date()
        var card = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        card.title = "Visa"
        card.entryType = .card
        var note = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        note.title = "Wifi"
        note.entryType = .notes
        note.notesBody = "lobby"
        session.mutate { db in
            db.rootGroup.entries.append(card)
            db.rootGroup.entries.append(note)
        }

        guard case .credentialList(let favorites) = service.handle(.listEntries(token: "t", category: "favorites", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected favorites")
        }
        XCTAssertEqual(favorites.map(\.title), ["Alpha Mail"])

        guard case .credentialList(let cards) = service.handle(.listEntries(token: "t", category: "cards", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected cards")
        }
        XCTAssertEqual(cards.map(\.title), ["Visa"])
        XCTAssertEqual(cards.first?.entryType, "Card")

        guard case .credentialList(let notes) = service.handle(.listEntries(token: "t", category: "notes", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected notes")
        }
        XCTAssertEqual(notes.map(\.title), ["Wifi"])

        guard case .credentialList(let found) = service.handle(.searchEntries(token: "t", query: "lobby", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected search results")
        }
        XCTAssertEqual(found.map(\.title), ["Wifi"])

        XCTAssertEqual(
            service.handle(.listEntries(token: "t", category: "nope", pairing: authorizedPairingSecret)),
            .error("unknown category")
        )
        XCTAssertEqual(
            service.handle(.searchEntries(token: "t", query: "   ", pairing: authorizedPairingSecret)),
            .credentialList([])
        )
    }

    func testCreateEntryAddsALoginTheSearchCanFind() {
        let response = service.handle(.createEntry(
            token: "t", entryType: "Login", title: "Created", username: "ada", password: "s3cret",
            url: "https://created.example", cardNumber: "", cardholderName: "", expiry: "",
            cvv: "", notes: "", favorite: false, match: "", otp: "", pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .entryCreated)
        guard case .credentialList(let found) = service.handle(.searchEntries(token: "t", query: "Created", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected the new login in search")
        }
        XCTAssertEqual(found.map(\.title), ["Created"])
        XCTAssertEqual(found.first?.username, "ada")
        XCTAssertEqual(found.first?.url, "https://created.example")
        guard case .credentialList(let logins) = service.handle(.listEntries(token: "t", category: "logins", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected logins")
        }
        XCTAssertTrue(logins.contains { $0.title == "Created" })
    }

    func testPasskeysCategoryAndMetadataAgreeAndExcludeTrashAndHistory() {
        let only = addFixtureEntry(title: "A passkey only", username: "alice", password: "", url: "https://example.com")
        let mixed = addFixtureEntry(title: "B mixed login", username: "bob", password: "pw", url: "https://example.com")
        let incomplete = addFixtureEntry(title: "C incomplete", username: "carol", password: "pw", url: "https://example.com")
        let deleted = addFixtureEntry(title: "Deleted", username: "d", password: "", url: "https://example.com")
        attachPasskey(to: only)
        attachPasskey(to: mixed)
        attachPasskey(to: incomplete, credentialId: nil)
        attachPasskey(to: deleted)
        moveEntryToRecycleBin(deleted)
        session.mutate { db in
            PasswordGeneratorHistoryStore.record(password: "generated", url: "https://example.com", createdAt: Date(), in: &db)
            let history = db.rootGroup.subgroups.first { PasswordGeneratorHistoryStore.isHistoryGroup($0) }!
            history.entries[0].passkeyCredentialId = Data([1])
            history.entries[0].passkeyPrivateKeyPEM = "fixture-key"
        }

        guard case .credentialList(let passkeys) = service.handle(.listEntries(
            token: "t", category: "passkeys", pairing: authorizedPairingSecret
        )) else { return XCTFail("expected passkeys category") }
        XCTAssertEqual(passkeys.map(\.id), [only.uuidString, mixed.uuidString])
        XCTAssertTrue(passkeys.allSatisfy(\.hasPasskey))
        for request in [
            ExtensionBridgeRequest.listEntries(token: "t", category: "all", pairing: authorizedPairingSecret),
            .getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret)
        ] {
            guard case .credentialList(let entries) = service.handle(request) else { return XCTFail("expected entries") }
            XCTAssertEqual(entries.first { $0.id == incomplete.uuidString }?.hasPasskey, false)
            XCTAssertEqual(entries.first { $0.id == only.uuidString }?.hasPasskey, true)
        }
    }

    func testPasskeysCategoryRequiresPairingAndUnlockedVault() {
        XCTAssertEqual(service.handle(.listEntries(token: "t", category: "passkeys", pairing: nil)), .pairingRequired)
        session.lock()
        XCTAssertEqual(service.handle(.listEntries(token: "t", category: "passkeys", pairing: authorizedPairingSecret)), .locked)
    }

    func testCreateEntryRejectsABlankTitle() {
        XCTAssertEqual(
            service.handle(.createEntry(
                token: "t", entryType: "Login", title: "  ", username: "", password: "",
                url: "", cardNumber: "", cardholderName: "", expiry: "", cvv: "", notes: "",
                favorite: false, match: "", otp: "", pairing: authorizedPairingSecret
            )),
            .error("title required")
        )
    }

    func testCreateEntryKeepsFavoriteMatchNotesAndOneTimePassword() {
        let response = service.handle(.createEntry(
            token: "t", entryType: "Login", title: "Created", username: "ada", password: "s3cret",
            url: "https://created.example/login", cardNumber: "", cardholderName: "", expiry: "",
            cvv: "", notes: "lobby", favorite: true, match: "host", otp: "JBSWY3DPEHPK3PXP",
            pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .entryCreated)
        let entry = session.currentDatabase?.rootGroup.entries.first { $0.title == "Created" }
        XCTAssertEqual(entry?.isFavorite, true)
        XCTAssertEqual(entry?.uriMatchMode, .host)
        XCTAssertEqual(entry?.notes, "lobby")
        XCTAssertEqual(entry?.totpSecretBase32, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry?.login, "ada")

        guard case .credentialList(let favorites) = service.handle(.getFavorites(token: "t", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected favorites")
        }
        XCTAssertTrue(favorites.contains { $0.title == "Created" })

        guard let id = entry?.uuid.uuidString else {
            return XCTFail("expected the created entry")
        }
        guard case .credential(let username, _, let totp) = service.handle(.fillCredential(
            token: "t", id: id, url: "https://created.example/login", pairing: authorizedPairingSecret
        )) else {
            return XCTFail("expected a fill")
        }
        XCTAssertEqual(username, "ada")
        XCTAssertEqual(totp?.count, 6)
    }

    func testCreateEntryDecodesAnOtpauthSecret() {
        let response = service.handle(.createEntry(
            token: "t", entryType: "Login", title: "Otp", username: "ada", password: "s3cret",
            url: "https://otp.example", cardNumber: "", cardholderName: "", expiry: "",
            cvv: "", notes: "", favorite: false, match: "nope",
            otp: "otpauth://totp/Ada?secret=JBSWY3DPEHPK3PXP&issuer=Ada",
            pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(response, .entryCreated)
        let entry = session.currentDatabase?.rootGroup.entries.first { $0.title == "Otp" }
        XCTAssertEqual(entry?.totpSecretBase32, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry?.uriMatchMode, .registrableDomain)
    }

    func testCreateEntryNeverModeStaysOutOfFavorites() {
        XCTAssertEqual(
            service.handle(.createEntry(
                token: "t", entryType: "Login", title: "Hidden", username: "ada", password: "s3cret",
                url: "https://hidden.example", cardNumber: "", cardholderName: "", expiry: "",
                cvv: "", notes: "", favorite: true, match: "never", otp: "",
                pairing: authorizedPairingSecret
            )),
            .entryCreated
        )
        guard case .credentialList(let favorites) = service.handle(.getFavorites(token: "t", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected favorites")
        }
        XCTAssertFalse(favorites.contains { $0.title == "Hidden" })
        guard case .credentialList(let logins) = service.handle(.listEntries(token: "t", category: "logins", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected logins")
        }
        XCTAssertTrue(logins.contains { $0.title == "Hidden" })
    }

    func testCreateEntryLoginTitleFallsBackToTheRegistrableDomain() {
        XCTAssertEqual(
            service.handle(.createEntry(
                token: "t", entryType: "Login", title: "  ", username: "", password: "",
                url: "https://login.example.com/path", cardNumber: "", cardholderName: "", expiry: "",
                cvv: "", notes: "", favorite: false, match: "", otp: "",
                pairing: authorizedPairingSecret
            )),
            .entryCreated
        )
        XCTAssertTrue(session.currentDatabase?.rootGroup.entries.contains { $0.title == "example.com" } == true)
    }

    func testCreateEntryCardUsesTheCardholderWhenTheTitleIsBlank() {
        XCTAssertEqual(
            service.handle(.createEntry(
                token: "t", entryType: "Card", title: "", username: "", password: "",
                url: "", cardNumber: "4242 4242 4242 4242", cardholderName: "Ada Lovelace", expiry: "12/30",
                cvv: "123", notes: "", favorite: false, match: "", otp: "",
                pairing: authorizedPairingSecret
            )),
            .entryCreated
        )
        let entry = session.currentDatabase?.rootGroup.entries.first { $0.title == "Ada Lovelace" }
        XCTAssertEqual(entry?.entryType, .card)
        XCTAssertEqual(entry?.cardNumber, "4242424242424242")
        XCTAssertEqual(entry?.login, "Ada Lovelace")
        XCTAssertEqual(entry?.expiryDate, "12/30")
        XCTAssertEqual(entry?.cvv, "123")
    }

    func testCreateEntryNoteStoresTheBodyAndFavorite() {
        XCTAssertEqual(
            service.handle(.createEntry(
                token: "t", entryType: "Notes", title: "Wifi", username: "", password: "",
                url: "", cardNumber: "", cardholderName: "", expiry: "",
                cvv: "", notes: "lobby password", favorite: true, match: "", otp: "",
                pairing: authorizedPairingSecret
            )),
            .entryCreated
        )
        let entry = session.currentDatabase?.rootGroup.entries.first { $0.title == "Wifi" }
        XCTAssertEqual(entry?.entryType, .notes)
        XCTAssertEqual(entry?.notesBody, "lobby password")
        XCTAssertEqual(entry?.isFavorite, true)
    }

    func testGetCredentialsExcludesNonMatchingDomain() {
        _ = addFixtureEntry(title: "Other", username: "bob", password: "pw", url: "https://other.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .credentialList([]))
    }

    func testNeverModeEntryIsAbsentFromTheCredentialListTheBridgeAssembles() {
        let id = addFixtureEntry(title: "Legacy", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) else { return }
            db.rootGroup.entries[index].uriMatchMode = .never
        }
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertTrue(
            summaries.isEmpty,
            "a never-mode entry must never be assembled into the credential list the bridge sends across the wire"
        )
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
    private func createFixtureRequestJSON(
        rpId: String = "example.com", origin: String = "https://example.com", excludeCredentials: [Data] = []
    ) -> String {
        let excluded = excludeCredentials
            .map { "{ \"type\": \"public-key\", \"id\": \"\(PasskeyBase64URL.encode($0))\" }" }
            .joined(separator: ", ")
        return """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1, 2, 3, 4])))",
          "rp": { "id": "\(rpId)", "name": "Example" },
          "user": { "id": "\(PasskeyBase64URL.encode(Data([9, 9])))", "name": "alice", "displayName": "Alice" },
          "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
          "attestation": "none",
          "excludeCredentials": [\(excluded)],
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

    func testGetCredentialsSetsHasPasskeyTrueWhenCredentialIDAndPrivateKeyPresent() {
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

    func testExcludedPasskeyIsRevealedOnlyAfterConsentAndNeverReplaced() {
        let id = addFixtureEntry(title: "Existing", username: "alice", password: "password", url: "https://example.com")
        let credentialID = Data([0xfb, 0xff, 0x01])
        attachPasskey(to: id, pem: "original-key", credentialId: credentialID)
        let request = createFixtureRequestJSON(excludeCredentials: [credentialID])
        guard case .passkeyCreatePending = service.handle(.passkeyCreate(
            token: "t", requestId: 70, requestDetailsJson: request,
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        )) else { return XCTFail("page-triggered request must still wait for consent") }

        guard case .passkeyCreateComplete(_, let responseJSON, let error) = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 70, entryId: id.uuidString, replace: true, pairing: authorizedPairingSecret
        )) else { return XCTFail("expected complete") }

        XCTAssertNil(responseJSON)
        XCTAssertEqual(error?.name, "InvalidStateError")
        let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.passkeyPrivateKeyPEM, "original-key")
        XCTAssertEqual(entries.first?.passkeyCredentialId, credentialID)
        guard case .passkeyCreateComplete(_, _, let retryError) = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 70, entryId: nil, replace: false, pairing: authorizedPairingSecret
        )) else { return XCTFail("expected complete") }
        XCTAssertEqual(retryError?.message, "No pending request")
    }

    func testExcludedPasskeyAddedWhileConfirmationIsOpenPreventsNewCredential() {
        let credentialID = Data([1, 2, 3])
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 71, requestDetailsJson: createFixtureRequestJSON(excludeCredentials: [credentialID]),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        let id = addFixtureEntry(title: "Arrived from sync", username: "alice", password: "", url: "https://example.com")
        attachPasskey(to: id, credentialId: credentialID)
        session.mutate { db in db.rootGroup.entries[0].uriMatchMode = .never }

        guard case .passkeyCreateComplete(_, let responseJSON, let error) = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 71, entryId: nil, replace: false, pairing: authorizedPairingSecret
        )) else { return XCTFail("expected complete") }
        XCTAssertNil(responseJSON)
        XCTAssertEqual(error?.name, "InvalidStateError")
        XCTAssertEqual(EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).count, 1)
    }

    func testExcludedCredentialForAnotherRPDoesNotBlockRegistration() {
        let id = addFixtureEntry(title: "Other RP", username: "alice", password: "", url: "https://other.example")
        attachPasskey(to: id, rpId: "other.example", credentialId: Data([1, 2, 3]))
        _ = service.handle(.passkeyCreate(
            token: "t", requestId: 72, requestDetailsJson: createFixtureRequestJSON(excludeCredentials: [Data([1, 2, 3])]),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreateComplete(_, let responseJSON, let error) = service.handle(.passkeyCreateConfirm(
            token: "t", requestId: 72, entryId: nil, replace: false, pairing: authorizedPairingSecret
        )) else { return XCTFail("expected complete") }
        XCTAssertNotNil(responseJSON)
        XCTAssertNil(error)
        XCTAssertEqual(EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).count, 2)
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

    /// Same rationale as `testPasskeyCreateExcludesNeverModeEntryFromRpIdMatchedCandidates`,
    /// exercised on the get/assertion path: `passkeyEntries(forRelyingParty:in:)` is the sole
    /// source of `passkeyGet`'s candidate list, so a never-mode entry holding a passkey for
    /// the requested rpId must not be assembled into it either.
    func testPasskeyGetExcludesNeverModeEntryFromRpIdMatchedCandidates() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        attachPasskey(to: id)
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) else { return }
            db.rootGroup.entries[index].uriMatchMode = .never
        }
        let response = service.handle(.passkeyGet(
            token: "t", requestId: 27, requestDetailsJson: getFixtureRequestJSON(),
            originUrl: "https://example.com", pairing: authorizedPairingSecret
        ))
        guard case .passkeyGetComplete(_, let responseJson, let error) = response else {
            return XCTFail("expected complete, got \(response)")
        }
        XCTAssertNil(responseJson)
        XCTAssertEqual(
            error?.name, "NotAllowedError",
            "a never-mode entry must never be assembled into the passkey-get candidate list the bridge sends across the wire"
        )
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

    /// `passkeyEntries(forRelyingParty:in:)` looks entries up by rpId, not by URL, so it
    /// never runs through `ExtensionEntryMatcher` and never-mode exclusion is not implied
    /// by anything else on the request path. Mirrors the shape of
    /// `testPasskeyCreateUnionsRpIdPasskeyEntriesWithDomainMatchesWithoutDuplicates`'s
    /// `passkeyOnly` fixture (no saved URL, so it can only ever surface through the rpId
    /// lookup) but sets `uriMatchMode` to `.never` instead of leaving it at the default,
    /// proving the exclusion at the actual bridge boundary that assembles the candidate
    /// list sent to the extension for a passkey-create prompt.
    func testPasskeyCreateExcludesNeverModeEntryFromRpIdMatchedCandidates() {
        let passkeyOnly = addFixtureEntry(title: "Old Passkey Entry", username: "carol", password: "s3cret", url: "")
        attachPasskey(to: passkeyOnly, rpId: "localhost")
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == passkeyOnly }) else { return }
            db.rootGroup.entries[index].uriMatchMode = .never
        }
        let response = service.handle(.passkeyCreate(
            token: "t", requestId: 26, requestDetailsJson: createFixtureRequestJSON(rpId: "localhost", origin: "http://localhost:8765"),
            originUrl: "http://localhost:8765", pairing: authorizedPairingSecret
        ))
        guard case .passkeyCreatePending(_, _, _, let matches) = response else { return XCTFail("expected pending, got \(response)") }
        XCTAssertTrue(
            matches.isEmpty,
            "a never-mode entry must never be assembled into the passkey-create candidate list the bridge sends across the wire"
        )
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

    func testAuthorizedPasskeyStatusPollingDoesNotResetIdleOrUnlockTheVault() throws {
        let recorder = SpyAutoLockActivityRecorder()
        let manager = ExtensionPairingManager(store: InMemoryExtensionPairingStore())
        let code = manager.startPairing(browser: "Status test")
        let pairing = try XCTUnwrap(manager.completePairing(code: code))
        let notifying = ExtensionBridgeService(
            vaultSession: session, pairingManager: manager, autoLockActivityRecorder: recorder
        )
        XCTAssertEqual(notifying.handle(.getPasskeyProxyStatus(token: "t", pairing: pairing)),
                       .passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: true, enabled: true))
        session.lock()
        XCTAssertEqual(notifying.handle(.getPasskeyProxyStatus(token: "t", pairing: pairing)),
                       .passkeyProxyStatus(unlocked: false, paired: true, attachAllowed: false, enabled: true))
        XCTAssertNil(session.currentDatabase)
        XCTAssertEqual(recorder.recordActivityCallCount, 0)
    }

    func testGeneratePasswordReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.generatePassword(token: "t", domain: "example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testGeneratePasswordNotifiesAutoLockActivityRecorderWhenServed() {
        let recorder = SpyAutoLockActivityRecorder()
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

        let response = notifying.handle(.generatePassword(token: "t", domain: "example.com", pairing: secret))

        guard case .generatedPassword = response else { return XCTFail("expected the request to actually be served") }
        XCTAssertEqual(recorder.recordActivityCallCount, 1, "a paired, served generatePassword is a deliberate user action and must reset the idle timer")
    }

    func testGeneratePasswordForADomainWithAKnownRuleProducesAPasswordSatisfyingItsLengthBounds() throws {
        let domain = "apple.com"
        let rules = try XCTUnwrap(
            PasswordRulesCatalog.rules(forHost: domain),
            "apple.com is expected to carry a rule in the vendored password-rules.json snapshot from Task 1"
        )
        let response = service.handle(.generatePassword(token: "t", domain: domain, pairing: authorizedPairingSecret))
        guard case .generatedPassword(let password) = response else {
            return XCTFail("expected generatedPassword, got \(response)")
        }
        if let minLength = rules.minLength {
            XCTAssertGreaterThanOrEqual(password.count, minLength)
        }
        if let maxLength = rules.maxLength {
            XCTAssertLessThanOrEqual(password.count, maxLength)
        }
    }

    /// `ssa.gov`'s vendored rule (`required: lower; required: upper; required: digit;
    /// required: [~!@#$%^&*];`) states no `minlength`/`maxlength` of its own, so the
    /// generator's requested length passes through unclamped — four required clauses
    /// can never fit in a 2-character password, which is exactly the shape of an
    /// unsatisfiable SITE rule (as opposed to the user's own toggles leaving nothing
    /// to draw from, covered separately below). `PasswordGeneratorDefaults.load()` in
    /// the handler always reads `UserDefaults.standard` (it is not injectable the way
    /// `PasswordRulesCatalog`/`PasswordGenerator` are), so this seeds and restores that
    /// key directly, mirroring `OpenExistingVaultTests.testRetargetClearsSecondarySyncCheckpoints`.
    func testGeneratePasswordReturnsSiteSpecificErrorWhenTheSitesRuleCannotBeSatisfied() throws {
        let domain = "ssa.gov"
        let rules = try XCTUnwrap(
            PasswordRulesCatalog.rules(forHost: domain),
            "ssa.gov is expected to carry a rule in the vendored password-rules.json snapshot from Task 1"
        )
        XCTAssertGreaterThan(
            rules.requiredClauses.count, 2,
            "this test relies on ssa.gov requiring more character classes than the 2-character length below can hold"
        )
        let priorLength = UserDefaults.standard.object(forKey: PasswordGeneratorDefaults.lengthKey)
        addTeardownBlock {
            if let priorLength {
                UserDefaults.standard.set(priorLength, forKey: PasswordGeneratorDefaults.lengthKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PasswordGeneratorDefaults.lengthKey)
            }
        }
        UserDefaults.standard.set(2, forKey: PasswordGeneratorDefaults.lengthKey)

        let response = service.handle(.generatePassword(token: "t", domain: domain, pairing: authorizedPairingSecret))

        XCTAssertEqual(response, .error("This site's password requirements could not be satisfied"))
    }

    /// The other of the two `PasswordGeneratorError` causes the handler distinguishes:
    /// here the user's own generator toggles (Settings > Password Generator) leave no
    /// character class enabled at all, unrelated to any site's rule — `example.com`
    /// carries no rule of its own, isolating this from `.unsatisfiableRules` above.
    func testGeneratePasswordReturnsSettingsSpecificErrorWhenNoCharacterClassIsEnabled() {
        let keys = [
            PasswordGeneratorDefaults.includeLowercaseKey,
            PasswordGeneratorDefaults.includeUppercaseKey,
            PasswordGeneratorDefaults.includeDigitsKey,
            PasswordGeneratorDefaults.includeSymbolsKey,
        ]
        let priorValues = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock {
            for (key, priorValue) in zip(keys, priorValues) {
                if let priorValue {
                    UserDefaults.standard.set(priorValue, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        for key in keys {
            UserDefaults.standard.set(false, forKey: key)
        }

        let response = service.handle(.generatePassword(token: "t", domain: "example.com", pairing: authorizedPairingSecret))

        XCTAssertEqual(
            response,
            .error("Your password generator has no character types enabled. Turn on at least one in Settings and try again.")
        )
    }

    func testGeneratedPasswordHistoryLivesInTheVaultAndStaysOutOfTheBrowserLists() {
        let loginID = addFixtureEntry(title: "GitLab", username: "ada", password: "saved", url: "https://gitlab.com/login")
        let before = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).count

        let recorded = service.handle(.recordGeneratedPassword(
            token: "t", password: "generated-secret", url: "https://gitlab.com/login",
            createdAt: 1_700_000_100_000, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(recorded, .acknowledged)

        let root = session.currentDatabase!.rootGroup
        XCTAssertEqual(EntrySearch.allEntries(in: root).count, before, "history rows are not vault logins")
        XCTAssertFalse(EntrySearch.allEntries(in: root).contains(where: { $0.password == "generated-secret" }))
        let group = root.subgroups.first { PasswordGeneratorHistoryStore.isHistoryGroup($0) }
        XCTAssertEqual(group?.name, PasswordGeneratorHistoryStore.groupName)
        XCTAssertEqual(group?.entries.count, 1)
        XCTAssertEqual(group?.entries.first?.password, "generated-secret")
        XCTAssertEqual(group?.entries.first?.title, "gitlab.com")
        XCTAssertEqual(group?.entries.first?.uriMatchMode, .never)
        XCTAssertEqual(group?.entries.first?.fields.first { $0.key == "Password" }?.isProtected, true)
        XCTAssertFalse(
            GroupTreeOperations.selectableGroups(in: root, excludingRecycleBin: nil)
                .contains { PasswordGeneratorHistoryStore.isHistoryGroup($0) }
        )

        let matches = service.handle(.getCredentials(
            token: "t", url: "https://gitlab.com/login", pairing: authorizedPairingSecret
        ))
        guard case .credentialList(let credentials) = matches else { return XCTFail("expected credentials") }
        XCTAssertEqual(credentials.map(\.id), [loginID.uuidString])

        let listed = service.handle(.getGeneratedPasswordHistory(token: "t", pairing: authorizedPairingSecret))
        guard case .passwordHistory(let items) = listed else { return XCTFail("expected history") }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].password, "generated-secret")
        XCTAssertEqual(items[0].url, "https://gitlab.com/login")
        XCTAssertEqual(items[0].createdAt, 1_700_000_100_000)

        let older = service.handle(.recordGeneratedPassword(
            token: "t", password: "older-secret", url: "",
            createdAt: 1_700_000_000_000, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(older, .acknowledged)
        guard case .passwordHistory(let ordered) = service.handle(.getGeneratedPasswordHistory(token: "t", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected history")
        }
        XCTAssertEqual(ordered.map(\.password), ["generated-secret", "older-secret"])
        XCTAssertEqual(ordered[1].createdAt, 1_700_000_000_000)
    }

    func testGeneratedPasswordHistoryKeepsTheNewestThirtyAndDeleteTombstonesOnlyHistory() {
        for index in 0..<31 {
            let response = service.handle(.recordGeneratedPassword(
                token: "t", password: "pw-\(index)", url: "https://example.com",
                createdAt: Double(index) * 1000, pairing: authorizedPairingSecret
            ))
            XCTAssertEqual(response, .acknowledged)
        }
        guard case .passwordHistory(let items) = service.handle(.getGeneratedPasswordHistory(token: "t", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected history")
        }
        XCTAssertEqual(items.count, 30)
        XCTAssertEqual(items.first?.password, "pw-30")
        XCTAssertFalse(items.contains { $0.password == "pw-0" })
        let database = session.currentDatabase!
        let group = database.rootGroup.subgroups.first { PasswordGeneratorHistoryStore.isHistoryGroup($0) }
        let kept = Set(group?.entries.map(\.uuid) ?? [])
        XCTAssertTrue(database.deletedObjects.contains { !kept.contains($0.uuid) }, "the oldest row is tombstoned so a sync does not bring it back")

        let loginID = addFixtureEntry(title: "Keep", username: "ada", password: "saved", url: "https://keep.example")
        let refused = service.handle(.deleteGeneratedPassword(token: "t", id: loginID.uuidString, pairing: authorizedPairingSecret))
        XCTAssertEqual(refused, .error("entry not found"))
        XCTAssertTrue(EntrySearch.allEntries(in: session.currentDatabase!.rootGroup).contains { $0.uuid == loginID })

        let removed = service.handle(.deleteGeneratedPassword(token: "t", id: items[0].id, pairing: authorizedPairingSecret))
        XCTAssertEqual(removed, .acknowledged)
        guard case .passwordHistory(let afterDelete) = service.handle(.getGeneratedPasswordHistory(token: "t", pairing: authorizedPairingSecret)) else {
            return XCTFail("expected history")
        }
        XCTAssertFalse(afterDelete.contains { $0.id == items[0].id })
        XCTAssertTrue(session.currentDatabase!.deletedObjects.contains { $0.uuid.uuidString == items[0].id })
    }

    func testGeneratedPasswordHistoryRefusesALockedOrUnpairedVault() {
        let unpaired = service.handle(.recordGeneratedPassword(
            token: "t", password: "pw", url: "https://example.com", createdAt: nil, pairing: nil
        ))
        XCTAssertEqual(unpaired, .pairingRequired)
        XCTAssertNil(session.currentDatabase?.rootGroup.subgroups.first { PasswordGeneratorHistoryStore.isHistoryGroup($0) })

        let blank = service.handle(.recordGeneratedPassword(
            token: "t", password: "   ", url: "", createdAt: nil, pairing: authorizedPairingSecret
        ))
        XCTAssertEqual(blank, .error("password required"))
        XCTAssertNil(session.currentDatabase?.rootGroup.subgroups.first { PasswordGeneratorHistoryStore.isHistoryGroup($0) })

        session.lock()
        let locked = service.handle(.getGeneratedPasswordHistory(token: "t", pairing: authorizedPairingSecret))
        XCTAssertEqual(locked, .locked)
    }
}

final class SpyAutoLockActivityRecorder: AutoLockActivityRecording {
    private(set) var recordActivityCallCount = 0
    func recordActivity() { recordActivityCallCount += 1 }
}
