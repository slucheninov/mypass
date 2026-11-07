import CryptoKit
import XCTest
@testable import MyPass

final class NoteDraftStoreTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let vault = "vault-a"
    private let entry = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(provider: DraftKeyProviding = InMemoryDraftKeyProvider(), unlocked: Bool = true) -> NoteDraftStore {
        let store = NoteDraftStore(directory: dir, keyProvider: provider, now: { [unowned self] in self.clock })
        if unlocked { store.unlock() }
        return store
    }

    private func draftFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "draft" }
    }

    func testRoundTripEncryptsAtRest() throws {
        let store = makeStore()
        XCTAssertTrue(store.save(notes: "secret note", vaultID: vault, entryID: entry))
        let files = draftFiles()
        XCTAssertEqual(files.count, 1)
        let raw = try Data(contentsOf: files[0])
        XCTAssertNil(raw.range(of: Data("secret note".utf8)))
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry).map(\.notes), ["secret note"])
    }

    func testRingBufferKeepsNewestTenAndEvictsOldest() {
        let store = makeStore()
        for i in 0..<12 { XCTAssertTrue(store.save(notes: "n\(i)", vaultID: vault, entryID: entry)) }
        let notes = store.versions(vaultID: vault, entryID: entry).map(\.notes)
        XCTAssertEqual(notes.count, 10)
        XCTAssertEqual(notes.first, "n11")
        XCTAssertEqual(notes.last, "n2")
    }

    func testIdenticalConsecutiveSaveIsSkipped() {
        let store = makeStore()
        XCTAssertTrue(store.save(notes: "a", vaultID: vault, entryID: entry))
        XCTAssertTrue(store.save(notes: "a", vaultID: vault, entryID: entry))
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry).count, 1)
    }

    func testEmptyNotesCanBeStored() {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        store.save(notes: "", vaultID: vault, entryID: entry)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry).map(\.notes), ["", "a"])
    }

    func testVersionsOlderThanSevenDaysArePurged() {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        clock = clock.addingTimeInterval(7 * 24 * 3600 + 1)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry), [])
        XCTAssertTrue(draftFiles().isEmpty)
    }

    func testVersionWithinSevenDaysSurvives() {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        clock = clock.addingTimeInterval(6 * 24 * 3600 + 23 * 3600)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry).count, 1)
    }

    func testTamperedCiphertextYieldsNoVersionsAndDeletesFile() throws {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        let file = draftFiles()[0]
        var raw = try Data(contentsOf: file)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: file)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry), [])
        XCTAssertTrue(draftFiles().isEmpty)
    }

    func testTruncatedFileYieldsNoVersions() throws {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        let file = draftFiles()[0]
        let raw = try Data(contentsOf: file)
        try raw.prefix(10).write(to: file)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry), [])
        XCTAssertTrue(draftFiles().isEmpty)
    }

    func testFileCopiedToAnotherEntryDoesNotDecrypt() throws {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        let other = UUID()
        let src = draftFiles()[0]
        let dst = src.deletingLastPathComponent().appendingPathComponent("\(other.uuidString).draft")
        try FileManager.default.copyItem(at: src, to: dst)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: other), [])
    }

    func testLockedStoreRefusesSaveAndList() {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        store.lock()
        XCTAssertFalse(store.save(notes: "b", vaultID: vault, entryID: entry))
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry), [])
        XCTAssertFalse(store.isAvailable)
    }

    func testUnlockAfterLockRestoresAccess() {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        store.lock()
        store.unlock()
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry).map(\.notes), ["a"])
    }

    func testUnavailableKeyProviderDisablesStoreAndWritesNothing() {
        let store = makeStore(provider: InMemoryDraftKeyProvider(key: nil))
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.save(notes: "a", vaultID: vault, entryID: entry))
        XCTAssertTrue(draftFiles().isEmpty)
    }

    func testDeleteAllRemovesOnlyThatEntry() {
        let store = makeStore()
        let other = UUID()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        store.save(notes: "b", vaultID: vault, entryID: other)
        store.deleteAll(vaultID: vault, entryID: entry)
        XCTAssertEqual(store.versions(vaultID: vault, entryID: entry), [])
        XCTAssertEqual(store.versions(vaultID: vault, entryID: other).count, 1)
    }

    func testDraftsAreSeparatedByVault() {
        let store = makeStore()
        store.save(notes: "a", vaultID: "v1", entryID: entry)
        XCTAssertEqual(store.versions(vaultID: "v2", entryID: entry), [])
        XCTAssertEqual(store.versions(vaultID: "v1", entryID: entry).count, 1)
    }

    func testDirectoryIsCreatedOwnerOnly() throws {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        let dirPath = draftFiles()[0].deletingLastPathComponent().path
        let perms = try FileManager.default.attributesOfItem(atPath: dirPath)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func testDraftFileAndRootDirectoryAreOwnerOnly() throws {
        let store = makeStore()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        let filePerms = try FileManager.default.attributesOfItem(atPath: draftFiles()[0].path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600)
        let rootPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(rootPerms, 0o700)
    }

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    func testKeychainProviderReturnsStableKey() throws {
        try requireKeychainTestsEnabled()
        let provider = KeychainDraftKeyProvider(service: "com.mypass.app.drafts.tests", account: "test-\(UUID().uuidString)")
        let a = try provider.loadOrCreateKey()
        let b = try provider.loadOrCreateKey()
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }
}
