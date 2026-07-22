import XCTest
import MyPassKit
@testable import MyPass

final class VaultSessionTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnlockWithNoExistingVaultCreatesEmptyDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.state, .locked)
        try session.unlock(password: "correct-horse")
        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.name, "MyPass")
        XCTAssertEqual(db.rootGroup.entries.count, 0)
    }

    func testUnlockWithWrongPasswordThrowsAndStaysLocked() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.lock()

        let secondSession = VaultSession(fileStore: fileStore)
        XCTAssertThrowsError(try secondSession.unlock(password: "wrong-password")) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }
        XCTAssertEqual(secondSession.state, .locked)
    }

    func testMutateAutosavesSoASecondSessionSeesTheChange() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        // Capture the on-disk bytes as they existed right after unlock (first-run
        // creation autosave), so we can detect once the *mutation's* autosave —
        // which now happens on a background queue — has actually landed on disk.
        let dataBeforeMutation = try fileStore.load()

        let now = Date()
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        session.mutate { database in
            var mutableEntry = entry
            mutableEntry.title = "Mutated Entry"
            database.rootGroup.entries.append(mutableEntry)
        }

        // mutate() updates in-memory state synchronously, but persist() now dispatches
        // the KDF derivation + file write to a background queue. Poll the file on disk
        // (short interval, small cap) until it changes from the pre-mutation snapshot,
        // rather than asserting immediately — this avoids a race against the async save
        // without introducing a long fixed sleep.
        var dataAfterMutation: Data?
        for _ in 0..<30 {
            let candidate = try fileStore.load()
            if candidate != dataBeforeMutation {
                dataAfterMutation = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotNil(dataAfterMutation, "expected the autosave to write new data to disk within the timeout")
        XCTAssertNil(session.lastSaveError)

        // A brand-new session pointed at the SAME fileStore/directory must be able to
        // unlock with the same password and see the mutation persisted to disk — this
        // is the end-to-end proof that mutate() now autosaves rather than only ever
        // writing once at first-run creation time.
        let secondSession = VaultSession(fileStore: fileStore)
        try secondSession.unlock(password: "correct-horse")
        guard case .unlocked(let db) = secondSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.entries.count, 1)
        XCTAssertEqual(db.rootGroup.entries.first?.title, "Mutated Entry")
    }

    /// Regression guard for the persist() data race: `KdbxGroup` is a reference
    /// type, so before the fix, `persist(_:)` captured `db` "by value" into a
    /// background closure while `rootGroup` remained the same live object that
    /// a subsequent `mutate()` call kept mutating on the main thread. Firing a
    /// second `mutate()` immediately after the first — before the first
    /// background save has necessarily completed — exercises exactly that
    /// back-to-back scenario (rapid entry creation / CSV import / fast
    /// drag-and-drop). This test can't deterministically force the exact race
    /// window (GCD scheduling isn't that controllable from a test), but it does
    /// prove that rapid repeated mutation never loses or corrupts either
    /// entry, which is the practical regression guard available here.
    func testRapidBackToBackMutationsBothPersistWithoutCorruption() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        func makeEntry(title: String) -> KdbxEntry {
            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(),
                iconID: 0,
                fields: [],
                creationTime: now,
                lastModificationTime: now,
                lastAccessTime: now,
                locationChanged: now,
                history: []
            )
            entry.title = title
            return entry
        }

        // Fire two mutations back-to-back with no delay in between, so the
        // first persist()'s background snapshot-and-save may still be in
        // flight when the second mutate() runs on the main thread.
        session.mutate { database in
            database.rootGroup.entries.append(makeEntry(title: "First Entry"))
        }
        session.mutate { database in
            database.rootGroup.entries.append(makeEntry(title: "Second Entry"))
        }

        // In-memory state must reflect both mutations immediately regardless
        // of the async saves still in flight.
        guard case .unlocked(let inMemoryDb) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(inMemoryDb.rootGroup.entries.count, 2)

        // Poll a freshly-opened session against the same fileStore until the
        // on-disk file reflects both entries (bounded retry, same pattern as
        // the existing async-autosave test above).
        // Each persist() performs a real Argon2id KDF derivation (64 MiB,
        // 3 iterations) plus a disk write, and this test triggers three of
        // them (unlock's first-run autosave + two mutate() autosaves) on a
        // dedicated serial background queue, so completion can lag a little
        // under system load. Poll with a generous-but-bounded retry budget
        // rather than a fixed short timeout that would make this test flaky.
        var sawBothEntries = false
        for _ in 0..<100 {
            if let data = try fileStore.load(),
               let db = try? KdbxDatabase.open(data: data, password: "correct-horse"),
               db.rootGroup.entries.count == 2 {
                let titles = Set(db.rootGroup.entries.map { $0.title })
                if titles == ["First Entry", "Second Entry"] {
                    sawBothEntries = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawBothEntries, "expected both rapid mutations to be reflected on disk within the timeout")
        XCTAssertNil(session.lastSaveError)
    }
}
