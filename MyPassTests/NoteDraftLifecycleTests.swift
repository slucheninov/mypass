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

    func testPermanentDeleteKeepsDraftsWhenMutateIsRejected() {
        let store = makeStore()
        let session = VaultSession(fileStore: VaultFileStore(directory: dir.appendingPathComponent("vault")))
        session.noteDraftStore = store
        store.save(notes: "keep me", vaultID: session.draftVaultID, entryID: entry)
        var discarded = false
        let token = NotificationCenter.default.addObserver(forName: .noteDraftsDiscarded, object: nil, queue: nil) { _ in discarded = true }
        defer { NotificationCenter.default.removeObserver(token) }
        // Locked session: mutate returns false.
        XCTAssertFalse(session.mutateDeletingNoteDrafts { _ in [entry] })
        XCTAssertEqual(store.versions(vaultID: session.draftVaultID, entryID: entry).map(\.notes), ["keep me"])
        XCTAssertFalse(discarded)
    }

    // MARK: - Durable draft deletion

    private func makeEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(uuid: entry, iconID: 0, fields: [], creationTime: now, lastModificationTime: now,
                         lastAccessTime: now, locationChanged: now, history: [])
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    }

    /// An unlocked session holding one saved entry (`entry`) and a draft for it.
    private func makeSessionWithEntryAndDraft() throws -> (VaultSession, ControllableVaultStore, NoteDraftStore) {
        let vaultStore = ControllableVaultStore(directory: dir.appendingPathComponent("vault"))
        let session = VaultSession(fileStore: vaultStore)
        let drafts = makeStore()
        session.noteDraftStore = drafts
        try session.unlock(password: "pw")
        session.mutate { $0.rootGroup.entries.append(self.makeEntry()) }
        waitUntil { vaultStore.saveCount >= 1 }
        drafts.save(notes: "draft", vaultID: session.draftVaultID, entryID: entry)
        return (session, vaultStore, drafts)
    }

    private func deleteEntry(_ session: VaultSession, id: UUID) -> Bool {
        session.mutateDeletingNoteDrafts { database in
            let removed = GroupTreeOperations.permanentlyDeleteEntry(
                withID: id, in: database.rootGroup, deletedObjects: &database.deletedObjects)
            return removed ? [id] : []
        }
    }

    func testPermanentDeleteRemovesDraftsOnceTheSaveIsDurable() throws {
        let (session, _, drafts) = try makeSessionWithEntryAndDraft()
        XCTAssertTrue(deleteEntry(session, id: entry))
        waitUntil { drafts.versions(vaultID: session.draftVaultID, entryID: self.entry).isEmpty }
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: entry), [])
        XCTAssertTrue(session.pendingDraftDeletionIDs.isEmpty)
    }

    func testPermanentDeleteOfStaleIDKeepsDraftsAndPostsNothing() throws {
        let (session, vaultStore, drafts) = try makeSessionWithEntryAndDraft()
        let stale = UUID()
        drafts.save(notes: "stale draft", vaultID: session.draftVaultID, entryID: stale)
        var discarded = false
        let token = NotificationCenter.default.addObserver(forName: .noteDraftsDiscarded, object: nil, queue: nil) { _ in discarded = true }
        defer { NotificationCenter.default.removeObserver(token) }
        let savesBefore = vaultStore.saveCount
        XCTAssertTrue(deleteEntry(session, id: stale))
        // Force a later durable save so a wrongly queued deletion would have run by now.
        session.mutate { $0.rootGroup.entries[0].title = "later" }
        waitUntil { vaultStore.saveCount > savesBefore }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: stale).map(\.notes), ["stale draft"])
        XCTAssertFalse(discarded)
        XCTAssertTrue(session.pendingDraftDeletionIDs.isEmpty)
    }

    func testFailedSaveKeepsDraftsPending() throws {
        let (session, vaultStore, drafts) = try makeSessionWithEntryAndDraft()
        vaultStore.failWrites(with: CocoaError(.fileWriteNoPermission))
        XCTAssertTrue(deleteEntry(session, id: entry))
        waitUntil { session.lastSaveError != nil }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: entry).map(\.notes), ["draft"])
        XCTAssertEqual(session.pendingDraftDeletionIDs, [entry])
    }

    func testFailureFollowedByLaterSuccessDeletesTheDrafts() throws {
        let (session, vaultStore, drafts) = try makeSessionWithEntryAndDraft()
        vaultStore.failWrites(with: CocoaError(.fileWriteNoPermission))
        XCTAssertTrue(deleteEntry(session, id: entry))
        waitUntil { session.lastSaveError != nil }
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: entry).map(\.notes), ["draft"])

        vaultStore.failWrites(with: nil)
        session.mutate { $0.rootGroup.name = "renamed" }
        waitUntil { drafts.versions(vaultID: session.draftVaultID, entryID: self.entry).isEmpty }
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: entry), [])
        XCTAssertTrue(session.pendingDraftDeletionIDs.isEmpty)
    }

    func testLockBeforeSuccessKeepsDraftsAndClearsPending() throws {
        let (session, vaultStore, drafts) = try makeSessionWithEntryAndDraft()
        vaultStore.holdWrites()
        XCTAssertTrue(deleteEntry(session, id: entry))
        XCTAssertEqual(session.pendingDraftDeletionIDs, [entry])
        session.lock()
        XCTAssertTrue(session.pendingDraftDeletionIDs.isEmpty)
        vaultStore.releaseWrites()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        drafts.unlock()
        XCTAssertEqual(drafts.versions(vaultID: session.draftVaultID, entryID: entry).map(\.notes), ["draft"])
    }

    func testDraftVaultIDIsStableHexAndDiffersPerPath() {
        let a = VaultSession.draftVaultID(forPath: "/a/vault.kdbx")
        XCTAssertEqual(a, VaultSession.draftVaultID(forPath: "/a/vault.kdbx"))
        XCTAssertNotEqual(a, VaultSession.draftVaultID(forPath: "/b/vault.kdbx"))
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(VaultSession.draftVaultID(forPath: nil), VaultSession.draftVaultID(forPath: "default"))
    }

    // MARK: - Orphan recovery (never-saved new entries)

    private func v(_ s: String, _ offset: TimeInterval) -> NoteDraftVersion {
        NoteDraftVersion(id: UUID(), savedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), notes: s)
    }

    func testNoOrphansGivesNil() {
        XCTAssertNil(NoteDraftRecovery.newestOrphan(candidates: [], databaseEntryIDs: []))
    }

    func testSingleOrphanIsOffered() {
        let id = UUID()
        let o = NoteDraftRecovery.newestOrphan(candidates: [(id, [v("a", 1), v("b", 2)])], databaseEntryIDs: [])
        XCTAssertEqual(o?.entryID, id)
        XCTAssertEqual(o?.draft.notes, "b")
    }

    func testNewestOrphanWins() {
        let old = UUID(), new = UUID()
        let o = NoteDraftRecovery.newestOrphan(
            candidates: [(old, [v("old", 1)]), (new, [v("new", 50)])], databaseEntryIDs: [])
        XCTAssertEqual(o?.entryID, new)
    }

    func testEntryPresentInDatabaseIsNotAnOrphan() {
        let saved = UUID()
        XCTAssertNil(NoteDraftRecovery.newestOrphan(candidates: [(saved, [v("x", 1)])], databaseEntryIDs: [saved]))
    }

    func testOrphanOwnedByLiveEditorIsExcluded() {
        let live = UUID(), dead = UUID()
        let o = NoteDraftRecovery.newestOrphan(
            candidates: [(live, [v("live", 50)]), (dead, [v("dead", 1)])],
            databaseEntryIDs: [], excluding: [live])
        XCTAssertEqual(o?.entryID, dead)
        XCTAssertNil(NoteDraftRecovery.newestOrphan(candidates: [(live, [v("live", 50)])],
                                                    databaseEntryIDs: [], excluding: [live]))
    }

    func testOrphanWithOnlyEmptyVersionsIsSkippedAndOlderNonEmptyWins() {
        let emptyOnly = UUID(), mixed = UUID()
        let o = NoteDraftRecovery.newestOrphan(
            candidates: [(emptyOnly, [v("", 90)]), (mixed, [v("", 80), v("text", 10)])], databaseEntryIDs: [])
        XCTAssertEqual(o?.entryID, mixed)
        XCTAssertEqual(o?.draft.notes, "text")
        XCTAssertNil(NoteDraftRecovery.newestOrphan(candidates: [(emptyOnly, [v("", 90)])], databaseEntryIDs: []))
    }

    func testSecondCreateEditorDoesNotOfferFirstEditorsDraft() {
        let store = makeStore()
        let first = NoteDraftEditorModel(store: store, vaultID: vault, entryID: UUID(), savedNotes: "",
                                         entryLastModified: nil, databaseEntryIDs: [])
        first.controller.noteTextChanged("window A typing")
        first.controller.flush()
        let second = NoteDraftEditorModel(store: store, vaultID: vault, entryID: UUID(), savedNotes: "",
                                          entryLastModified: nil, databaseEntryIDs: [])
        XCTAssertNil(second.pendingDraft)
        first.discardAfterSave()
        let third = NoteDraftEditorModel(store: store, vaultID: vault, entryID: UUID(), savedNotes: "",
                                         entryLastModified: nil, databaseEntryIDs: [])
        XCTAssertNil(third.pendingDraft) // saved and deleted, nothing left
    }

    func testDraftEntryIDsListsFilesOfThisVaultOnly() {
        let store = makeStore()
        let other = UUID()
        store.save(notes: "a", vaultID: vault, entryID: entry)
        store.save(notes: "b", vaultID: "vault-b", entryID: other)
        XCTAssertEqual(store.draftEntryIDs(vaultID: vault), [entry])
    }

    func testCreateEditorAdoptsOrphanAndSaveDeletesItsDrafts() {
        let store = makeStore()
        let orphan = UUID()
        store.save(notes: "lost note", vaultID: vault, entryID: orphan)
        let fresh = UUID()
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: fresh, savedNotes: "",
                                         entryLastModified: nil, databaseEntryIDs: [])
        XCTAssertEqual(model.pendingDraft?.notes, "lost note")
        model.restore(model.pendingDraft!)
        XCTAssertEqual(model.entryID, orphan)
        model.controller.noteTextChanged("lost note, edited")
        model.controller.flush()
        XCTAssertEqual(notes(store, orphan), ["lost note, edited", "lost note"])
        XCTAssertEqual(notes(store, fresh), [])
        model.discardAfterSave()
        XCTAssertEqual(notes(store, orphan), [])
    }

    func testCreateEditorDiscardingOrphanDeletesItsDrafts() {
        let store = makeStore()
        let orphan = UUID()
        store.save(notes: "lost note", vaultID: vault, entryID: orphan)
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: UUID(), savedNotes: "",
                                         entryLastModified: nil, databaseEntryIDs: [])
        model.deleteDrafts()
        XCTAssertEqual(notes(store, orphan), [])
        XCTAssertNil(model.pendingDraft)
    }

    func testEditModeDoesNotLookForOrphans() {
        let store = makeStore()
        store.save(notes: "lost note", vaultID: vault, entryID: UUID())
        let model = NoteDraftEditorModel(store: store, vaultID: vault, entryID: entry, savedNotes: "s",
                                         entryLastModified: Date(), databaseEntryIDs: nil)
        XCTAssertNil(model.pendingDraft)
    }

    // MARK: - Quit and sibling windows

    func testWillTerminateFlushesPendingDraft() {
        let store = makeStore()
        let center = NotificationCenter()
        let c = NoteDraftController(store: store, vaultID: vault, entryID: entry, baselineNotes: "base")
        c.attachLifecycleObservers(center: center)
        c.noteTextChanged("typed")
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(notes(store), ["typed"])
    }

    func testDiscardNotificationStopsSiblingControllerForThatEntryOnly() {
        let store = makeStore()
        let center = NotificationCenter()
        let sibling = NoteDraftController(store: store, vaultID: vault, entryID: entry, baselineNotes: "base")
        sibling.attachLifecycleObservers(center: center)
        center.post(name: .noteDraftsDiscarded, object: nil, userInfo: ["entryID": UUID()])
        sibling.noteTextChanged("still live")
        sibling.flush()
        XCTAssertEqual(notes(store), ["still live"])
        center.post(name: .noteDraftsDiscarded, object: nil, userInfo: ["entryID": entry])
        sibling.noteTextChanged("late")
        sibling.flush()
        XCTAssertEqual(notes(store), ["still live"])
    }
}
