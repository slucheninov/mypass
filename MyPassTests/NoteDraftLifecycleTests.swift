import AppKit
import XCTest
import MyPassKit
@testable import MyPass

@MainActor
final class NoteDraftLifecycleTests: XCTestCase {
    private var dir: URL!
    private let vault = "vault-a"
    private let entry = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("life-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> NoteDraftStore {
        let s = NoteDraftStore(directory: dir, keyProvider: InMemoryDraftKeyProvider())
        s.unlock()
        return s
    }

    private func notes(_ store: NoteDraftStore, _ id: UUID? = nil) -> [String] {
        store.versions(vaultID: vault, entryID: id ?? entry).map(\.notes)
    }

    func testWillLockNotificationFlushesPendingDraft() {
        let store = makeStore()
        let center = NotificationCenter()
        let c = NoteDraftController(store: store, vaultID: vault, entryID: entry, baselineNotes: "base")
        c.attachLifecycleObservers(center: center)
        c.noteTextChanged("typed before lock")
        center.post(name: .vaultWillLock, object: nil)
        XCTAssertEqual(notes(store), ["typed before lock"])
    }

    func testResignActiveFlushesPendingDraft() {
        let store = makeStore()
        let center = NotificationCenter()
        let c = NoteDraftController(store: store, vaultID: vault, entryID: entry, baselineNotes: "base")
        c.attachLifecycleObservers(center: center)
        c.noteTextChanged("typed")
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(notes(store), ["typed"])
    }

    func testSaveDeletesDraftsOfThatEntryOnly() {
        let store = makeStore()
        let other = UUID()
        store.save(notes: "other draft", vaultID: vault, entryID: other)
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "base", entryLastModified: nil)
        model.controller.noteTextChanged("edited")
        model.controller.flush()
        XCTAssertEqual(notes(store), ["edited"])
        model.discardAfterSave()
        XCTAssertEqual(notes(store), [])
        XCTAssertEqual(notes(store, other), ["other draft"])
        // The view disappearing after Save must not resurrect the draft.
        model.controller.noteTextChanged("late")
        model.controller.flush()
        XCTAssertEqual(notes(store), [])
    }

    func testCancelKeepsDrafts() {
        let store = makeStore()
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "base", entryLastModified: nil)
        model.controller.noteTextChanged("unsaved")
        model.cancel()
        XCTAssertEqual(notes(store), ["unsaved"])
    }

    func testReopeningOffersTheKeptDraftAndRestoreRequestsReplaceAll() {
        let store = makeStore()
        store.save(notes: "kept", vaultID: vault, entryID: entry)
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "base", entryLastModified: nil)
        XCTAssertEqual(model.pendingDraft?.notes, "kept")
        var received: [String] = []
        let token = model.restoreRequests.sink { received.append($0) }
        model.restore(model.pendingDraft!)
        token.cancel()
        XCTAssertEqual(received, ["kept"])
        guard case .replaceAll(let text) = NotesEditorCard.command(forRestoring: received[0]) else {
            return XCTFail("restore must be an undoable replaceAll command")
        }
        XCTAssertEqual(text, "kept")
        XCTAssertNil(model.pendingDraft)
    }

    func testRestoringTheNewestDraftThenCancelWritesNoDuplicateVersion() {
        let store = makeStore()
        store.save(notes: "kept", vaultID: vault, entryID: entry)
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "base", entryLastModified: nil)
        model.restore(model.pendingDraft!)
        model.controller.noteTextChanged("kept")
        model.cancel()
        XCTAssertEqual(notes(store), ["kept"])
    }

    func testDeleteRemovesDraftsAndBanner() {
        let store = makeStore()
        store.save(notes: "kept", vaultID: vault, entryID: entry)
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "base", entryLastModified: nil)
        model.deleteDrafts()
        XCTAssertNil(model.pendingDraft)
        XCTAssertEqual(notes(store), [])
    }

    func testRestoreFromVersionsListPicksTheChosenVersion() {
        let a = NoteDraftVersion(id: UUID(), savedAt: Date(), notes: "a")
        let b = NoteDraftVersion(id: UUID(), savedAt: Date(), notes: "b")
        XCTAssertEqual(NoteDraftRecovery.version(id: a.id, in: [b, a]), a)
        XCTAssertNil(NoteDraftRecovery.version(id: UUID(), in: [a, b]))
    }

    func testVaultSessionLockLocksTheDraftStore() throws {
        let fileStore = VaultFileStore(directory: dir.appendingPathComponent("vault"))
        let session = VaultSession(fileStore: fileStore)
        let store = makeStore()
        session.noteDraftStore = store
        store.save(notes: "x", vaultID: session.draftVaultID, entryID: entry)
        try session.unlock(password: "pw")
        session.lock()
        XCTAssertEqual(store.versions(vaultID: session.draftVaultID, entryID: entry), [])
        XCTAssertFalse(store.isAvailable)
    }

    func testVaultSessionLockPostsWillLockBeforeLockingStore() throws {
        let fileStore = VaultFileStore(directory: dir.appendingPathComponent("vault"))
        let session = VaultSession(fileStore: fileStore)
        let store = makeStore()
        session.noteDraftStore = store
        let c = NoteDraftController(store: store, vaultID: session.draftVaultID, entryID: entry, baselineNotes: "base")
        c.attachLifecycleObservers(center: .default)
        c.noteTextChanged("in flight")
        try session.unlock(password: "pw")
        session.lock()
        store.unlock()
        XCTAssertEqual(store.versions(vaultID: session.draftVaultID, entryID: entry).map(\.notes), ["in flight"])
    }

    func testPermanentDeleteRemovesDrafts() {
        let store = makeStore()
        let fileStore = VaultFileStore(directory: dir.appendingPathComponent("vault"))
        let session = VaultSession(fileStore: fileStore)
        session.noteDraftStore = store
        store.save(notes: "x", vaultID: session.draftVaultID, entryID: entry)
        session.deleteNoteDrafts(entryIDs: [entry])
        XCTAssertEqual(store.versions(vaultID: session.draftVaultID, entryID: entry), [])
    }

    func testDraftVaultIDIsStableHexAndDiffersPerPath() {
        let a = VaultSession.draftVaultID(forPath: "/a/vault.kdbx")
        XCTAssertEqual(a, VaultSession.draftVaultID(forPath: "/a/vault.kdbx"))
        XCTAssertNotEqual(a, VaultSession.draftVaultID(forPath: "/b/vault.kdbx"))
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(VaultSession.draftVaultID(forPath: nil), VaultSession.draftVaultID(forPath: "default"))
    }
}
