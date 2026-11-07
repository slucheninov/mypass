import XCTest
@testable import MyPass

@MainActor
final class NoteDraftControllerTests: XCTestCase {
    private var dir: URL!
    private let vault = "vault-a"
    private let entry = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctrl-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(unlocked: Bool = true) -> NoteDraftStore {
        let s = NoteDraftStore(directory: dir, keyProvider: InMemoryDraftKeyProvider())
        if unlocked { s.unlock() }
        return s
    }

    private func makeController(_ store: NoteDraftStore, baseline: String = "base") -> NoteDraftController {
        NoteDraftController(store: store, vaultID: vault, entryID: entry, baselineNotes: baseline)
    }

    private func notes(_ store: NoteDraftStore) -> [String] {
        store.versions(vaultID: vault, entryID: entry).map(\.notes)
    }

    func testTickWithoutChangeWritesNothing() {
        let store = makeStore()
        let c = makeController(store)
        c.tick()
        XCTAssertEqual(notes(store), [])
        XCTAssertNil(c.lastSavedAt)
    }

    func testTickAfterChangeWritesOnceThenSkipsUntilNextChange() {
        let store = makeStore()
        let c = makeController(store)
        c.noteTextChanged("one")
        c.tick(); c.tick()
        XCTAssertEqual(notes(store), ["one"])
        c.noteTextChanged("two")
        c.tick()
        XCTAssertEqual(notes(store), ["two", "one"])
    }

    func testFlushWritesPendingChangeImmediately() {
        let store = makeStore()
        let c = makeController(store)
        c.noteTextChanged("pending")
        c.flush()
        XCTAssertEqual(notes(store), ["pending"])
        XCTAssertNotNil(c.lastSavedAt)
    }

    func testClearingAllTextWritesEmptyVersionWhenBaselineWasNonEmpty() {
        let store = makeStore()
        let c = makeController(store, baseline: "something")
        c.noteTextChanged("")
        c.tick()
        XCTAssertEqual(notes(store), [""])
    }

    func testEditThenRevertToBaselineWritesNothingNew() {
        let store = makeStore()
        let c = makeController(store)
        c.noteTextChanged("typed")
        c.noteTextChanged("base")
        c.tick()
        XCTAssertEqual(notes(store), [])
        XCTAssertNil(c.lastSavedAt)
    }

    func testLastSavedAtSetOnlyOnSuccess() {
        let store = makeStore(unlocked: false)
        let c = makeController(store)
        c.noteTextChanged("x")
        c.flush()
        XCTAssertNil(c.lastSavedAt)
        store.unlock()
        c.flush()
        XCTAssertNotNil(c.lastSavedAt)
        XCTAssertEqual(notes(store), ["x"])
    }

    func testEnabledWhenStoreUnlocked() {
        XCTAssertTrue(makeController(makeStore()).isEnabled)
    }

    func testDisabledWhenStoreUnavailable() {
        let store = makeStore(unlocked: false)
        let c = makeController(store)
        XCTAssertFalse(c.isEnabled)
        c.noteTextChanged("x")
        c.tick(); c.flush()
        XCTAssertNil(c.lastSavedAt)
    }
}

final class NoteDraftRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func v(_ s: String, _ offset: TimeInterval) -> NoteDraftVersion {
        NoteDraftVersion(id: UUID(), savedAt: t0.addingTimeInterval(offset), notes: s)
    }

    func testNewestDifferingNewerDraftIsOffered() {
        let versions = [v("c", 30), v("b", 20), v("a", 10)]
        let r = NoteDraftRecovery.pendingDraft(versions: versions, savedNotes: "saved", entryLastModified: t0)
        XCTAssertEqual(r?.notes, "c")
    }

    func testDraftEqualToSavedNotesIsIgnored() {
        let versions = [v("saved", 30), v("older", 20)]
        let r = NoteDraftRecovery.pendingDraft(versions: versions, savedNotes: "saved", entryLastModified: t0)
        XCTAssertEqual(r?.notes, "older")
        XCTAssertNil(NoteDraftRecovery.pendingDraft(versions: [v("saved", 30)], savedNotes: "saved", entryLastModified: t0))
    }

    func testDraftOlderThanLastSaveIsIgnored() {
        let r = NoteDraftRecovery.pendingDraft(versions: [v("x", 10)], savedNotes: "saved", entryLastModified: t0.addingTimeInterval(50))
        XCTAssertNil(r)
    }

    func testDraftSavedExactlyAtLastModificationIsIgnored() {
        XCTAssertNil(NoteDraftRecovery.pendingDraft(versions: [v("x", 0)], savedNotes: "saved", entryLastModified: t0))
        XCTAssertNotNil(NoteDraftRecovery.pendingDraft(versions: [v("x", 0.001)], savedNotes: "saved", entryLastModified: t0))
    }

    func testEmptyVersionsGivesNil() {
        XCTAssertNil(NoteDraftRecovery.pendingDraft(versions: [], savedNotes: "s", entryLastModified: t0))
    }
}
