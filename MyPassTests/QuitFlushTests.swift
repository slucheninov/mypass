import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

/// A store whose writes can be held back, failed, and counted.
final class ControllableVaultStore: VaultPrimaryStorage {
    private let inner: VaultFileStore
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    private var failure: Error?
    private(set) var saveCount = 0

    init(directory: URL) { inner = VaultFileStore(directory: directory) }

    func holdWrites() { lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock() }
    func releaseWrites() { lock.lock(); let g = gate; gate = nil; lock.unlock(); g?.signal() }
    func failWrites(with error: Error?) { lock.lock(); failure = error; lock.unlock() }

    func load() throws -> Data? { try inner.load() }
    var primaryVaultFileURL: URL? { inner.primaryVaultFileURL }
    func deleteVaultFileIfPresent() throws { try inner.deleteVaultFileIfPresent() }
    func save(data: Data) throws {
        lock.lock(); let g = gate; let f = failure; lock.unlock()
        g?.wait()
        if let f { throw f }
        lock.lock(); saveCount += 1; lock.unlock()
        try inner.save(data: data)
    }
}

final class VaultFlushTests: XCTestCase {
    private let password = "correct-horse"
    private var directory: URL!
    private var store: ControllableVaultStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultFlushTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ControllableVaultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store.releaseWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private func addEntry(_ session: VaultSession, title: String) {
        session.mutate { db in
            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now,
                lastAccessTime: now, locationChanged: now, history: []
            )
            entry.title = title
            db.rootGroup.entries.append(entry)
        }
    }

    private func titlesOnDisk() throws -> [String] {
        let data = try XCTUnwrap(try store.load())
        return try KdbxDatabase.open(data: data, password: password).rootGroup.entries.map(\.title)
    }

    private func flush(_ session: VaultSession, timeout: TimeInterval = 5, patience: TimeInterval = 8, during: (() -> Void)? = nil) -> [VaultFlushOutcome] {
        let done = expectation(description: "flush completes")
        var outcomes: [VaultFlushOutcome] = []
        session.flushPendingWrites(timeout: timeout) { outcome in
            outcomes.append(outcome)
            done.fulfill()
        }
        during?()
        wait(for: [done], timeout: patience)
        // Give a stray second completion (a bug) a chance to show up.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return outcomes
    }

    func testIdleSessionFlushesImmediately() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        XCTAssertEqual(flush(session), [.flushed])
    }

    func testQueuedWriteIsWaitedForAndReachesDisk() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "queued")

        let outcomes = flush(session) { self.store.releaseWrites() }
        XCTAssertEqual(outcomes, [.flushed])
        XCTAssertEqual(try titlesOnDisk(), ["queued"])
    }

    func testQueuedWriteIsStillWaitedForWhenTheSessionWasLockedAfterwards() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "saved-then-locked")
        session.lock()
        XCTAssertEqual(session.state, .locked)

        let outcomes = flush(session) { self.store.releaseWrites() }
        XCTAssertEqual(outcomes, [.flushed])
        XCTAssertEqual(try titlesOnDisk(), ["saved-then-locked"], "locking must not lose a write that was already queued")
    }

    func testPendingDebouncedTouchAccessIsWrittenNowNotAfterTheDebounce() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        addEntry(session, title: "touched")
        XCTAssertEqual(flush(session), [.flushed])
        session.resumeAfterCancelledQuit() // the flush froze the session; this test keeps using it
        let entryID = try XCTUnwrap(session.currentDatabase?.rootGroup.entries.first?.uuid)
        let savesBefore = store.saveCount

        session.touchAccess(entryID: entryID)
        XCTAssertTrue(session.hasPendingTouchAccessPersist)
        let started = Date()
        XCTAssertEqual(flush(session), [.flushed])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.4, "must not sit out the 1.5 s debounce")
        XCTAssertFalse(session.hasPendingTouchAccessPersist)
        XCTAssertEqual(store.saveCount, savesBefore + 1)
    }

    func testSaveErrorIsPreservedNotSwallowed() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.failWrites(with: CocoaError(.fileWriteNoPermission))
        addEntry(session, title: "doomed")

        let outcomes = flush(session)
        guard case .saveFailed(let detail) = outcomes.first, outcomes.count == 1 else {
            return XCTFail("expected exactly one saveFailed, got \(outcomes)")
        }
        XCTAssertTrue(detail.contains("Failed to save changes"), detail)
        XCTAssertEqual(session.lastSaveError, detail, "the error stays visible to the UI too")
    }

    func testSaveErrorIsReportedEvenIfTheSessionWasLockedAfterwards() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.failWrites(with: CocoaError(.fileWriteNoPermission))
        addEntry(session, title: "doomed")
        session.lock()
        guard case .saveFailed = flush(session).first else { return XCTFail("a failed write must still be reported after lock()") }
    }

    /// Reproduces how `NSApp.terminate` waits for a `terminateLater` reply: in a
    /// nested run loop that sits inside a main-queue block when terminate was
    /// reached from a notification callback. libdispatch does not run further
    /// main-queue blocks in that state, so the completion must not need them.
    private func flushWaitedForInsideAMainQueueBlock(session: VaultSession, timeout: TimeInterval, release: (() -> Void)? = nil) -> VaultFlushOutcome? {
        let done = expectation(description: "nested wait finished")
        var outcome: VaultFlushOutcome?
        DispatchQueue.main.async {
            session.flushPendingWrites(timeout: timeout) { outcome = $0 }
            release?()
            let deadline = Date(timeIntervalSinceNow: 6)
            while outcome == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    func testFlushCompletesWhileWaitedForInsideAMainQueueBlock() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "nested")
        XCTAssertEqual(flushWaitedForInsideAMainQueueBlock(session: session, timeout: 5, release: { self.store.releaseWrites() }), .flushed)
        XCTAssertEqual(try titlesOnDisk(), ["nested"])
    }

    func testFlushTimeoutFiresWhileWaitedForInsideAMainQueueBlock() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "nested-stuck")
        XCTAssertEqual(flushWaitedForInsideAMainQueueBlock(session: session, timeout: 0.3), .timedOut)
        store.releaseWrites()
    }

    func testStuckWriteTimesOutOnceWithoutBlockingTheMainThread() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "stuck")

        let started = Date()
        let outcomes = flush(session, timeout: 0.3, patience: 3)
        XCTAssertEqual(outcomes, [.timedOut], "exactly one completion, even after the write later finishes")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)

        store.releaseWrites()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(try titlesOnDisk(), ["stuck"], "the write still completes after the timeout; nothing is cancelled")
    }
}

/// A remote whose uploads can be held back, standing in for a slow SFTP/iCloud sync.
final class GatedStorageBackend: StorageBackend {
    private let inner = InMemoryStorageBackend()
    private let lock = NSLock()
    private var gate: DispatchSemaphore?

    func holdWrites() { lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock() }
    func releaseWrites() { lock.lock(); let g = gate; gate = nil; lock.unlock(); g?.signal() }

    func read() throws -> Data? { try inner.read() }
    func modificationDate() throws -> Date? { try inner.modificationDate() }
    func exists() throws -> Bool { try inner.exists() }
    func write(_ data: Data) throws {
        lock.lock(); let g = gate; lock.unlock()
        g?.wait()
        try inner.write(data)
    }
}

/// The quit-time flush must account for every ACKNOWLEDGED change: anything the session accepted
/// before the flush is on disk when it completes, and anything arriving afterwards is refused
/// explicitly rather than accepted and then lost to the process exit.
final class VaultFlushQuiescenceTests: XCTestCase {
    private let password = "correct-horse"
    private var directory: URL!
    private var store: ControllableVaultStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultFlushQuiescenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ControllableVaultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store.releaseWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private func addEntry(_ session: VaultSession, title: String) {
        session.mutate { db in
            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now,
                lastAccessTime: now, locationChanged: now, history: []
            )
            entry.title = title
            db.rootGroup.entries.append(entry)
        }
    }

    private func memoryTitles(_ session: VaultSession) -> [String] {
        session.currentDatabase?.rootGroup.entries.map(\.title) ?? []
    }

    private func titlesOnDisk() throws -> [String] {
        let data = try XCTUnwrap(try store.load())
        return try KdbxDatabase.open(data: data, password: password).rootGroup.entries.map(\.title)
    }

    private func flush(_ session: VaultSession, timeout: TimeInterval = 5, patience: TimeInterval = 8, during: (() -> Void)? = nil) -> [VaultFlushOutcome] {
        let done = expectation(description: "flush completes")
        var outcomes: [VaultFlushOutcome] = []
        session.flushPendingWrites(timeout: timeout) { outcome in
            outcomes.append(outcome)
            done.fulfill()
        }
        during?()
        wait(for: [done], timeout: patience)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return outcomes
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    }

    // MARK: Mutations arriving while the flush waits

    func testMutationArrivingAfterTheFlushStartedIsRefusedNotAcknowledgedAndLost() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        addEntry(session, title: "before-flush")
        waitUntil { ((try? self.titlesOnDisk()) ?? []) == ["before-flush"] }
        XCTAssertEqual(try titlesOnDisk(), ["before-flush"])
        // From here every further local write blocks, so a mutation that gets accepted after the
        // flush marker cannot have reached disk by the time the flush reports completion.
        store.holdWrites()

        let outcomes = flush(session) {
            // The bridge or the UI gets a request in after the flush began, before it finished.
            self.addEntry(session, title: "after-flush")
        }
        XCTAssertEqual(outcomes, [.flushed])
        XCTAssertEqual(try titlesOnDisk(), ["before-flush"], "the save accepted before the flush is on disk")
        XCTAssertEqual(memoryTitles(session), try titlesOnDisk(), "nothing the session still holds as accepted may be missing from disk")
    }

    func testMutationIsRefusedExplicitlyWhileQuitIsInProgress() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        XCTAssertEqual(flush(session), [.flushed])

        XCTAssertTrue(session.isQuitInProgress)
        XCTAssertFalse(session.mutate { _ in XCTFail("the body must not run once the vault is frozen for quit") })
    }

    func testMutationsAreStillAcceptedBeforeTheFlushAndReportSuccess() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        XCTAssertFalse(session.isQuitInProgress)
        XCTAssertTrue(session.mutate { _ in })
    }

    func testLateTouchAccessAfterTheFlushStartedIsRefusedAndLeavesNoDebouncedWrite() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        addEntry(session, title: "touched")
        XCTAssertEqual(flush(session), [.flushed])
        session.resumeAfterCancelledQuit()
        let entryID = try XCTUnwrap(session.currentDatabase?.rootGroup.entries.first?.uuid)

        session.touchAccess(entryID: entryID)
        XCTAssertTrue(session.hasPendingTouchAccessPersist)
        let accessBefore = try XCTUnwrap(session.currentDatabase?.rootGroup.entries.first?.lastAccessTime)
        XCTAssertEqual(flush(session) { session.touchAccess(entryID: entryID) }, [.flushed])
        let savesAfterFlush = store.saveCount

        XCTAssertFalse(session.hasPendingTouchAccessPersist, "a touch after the flush must not arm a debounce that exit would drop")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.8))
        XCTAssertEqual(store.saveCount, savesAfterFlush, "no write may start after the flush completed")
        let accessAfter = try XCTUnwrap(session.currentDatabase?.rootGroup.entries.first?.lastAccessTime)
        XCTAssertEqual(accessAfter, accessBefore, "a refused touch must not change what the session reports")
    }

    func testPendingTouchBeforeTheFlushIsStillWritten() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        addEntry(session, title: "touched")
        XCTAssertEqual(flush(session), [.flushed])
        session.resumeAfterCancelledQuit()
        let entryID = try XCTUnwrap(session.currentDatabase?.rootGroup.entries.first?.uuid)
        let savesBefore = store.saveCount

        session.touchAccess(entryID: entryID)
        XCTAssertEqual(flush(session), [.flushed])
        XCTAssertEqual(store.saveCount, savesBefore + 1, "the debounced touch accepted before the flag is included")
    }

    func testLockingAfterEnqueueStillDrainsAndAnyLateMutationIsRefused() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "queued-then-locked")

        let outcomes = flush(session) {
            session.lock()
            self.addEntry(session, title: "while-locked")
            self.store.releaseWrites()
        }
        XCTAssertEqual(outcomes, [.flushed])
        XCTAssertEqual(try titlesOnDisk(), ["queued-then-locked"])
    }

    func testCancelledQuitResumesAcceptingMutations() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        XCTAssertEqual(flush(session), [.flushed])
        XCTAssertFalse(session.mutate { _ in })

        session.resumeAfterCancelledQuit()
        XCTAssertFalse(session.isQuitInProgress)
        addEntry(session, title: "after-cancel")
        XCTAssertEqual(flush(session), [.flushed])
        XCTAssertEqual(try titlesOnDisk(), ["after-cancel"])
    }

    func testTimeoutThenLateDrainStillCompletesExactlyOnceAndStaysFrozen() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.holdWrites()
        addEntry(session, title: "stuck")

        let outcomes = flush(session, timeout: 0.3, patience: 3)
        XCTAssertEqual(outcomes, [.timedOut])
        XCTAssertTrue(session.isQuitInProgress, "the prompt after a timeout is still part of the quit")
        store.releaseWrites()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        XCTAssertEqual(try titlesOnDisk(), ["stuck"])
    }

    func testMigrationIsRefusedWhileQuitIsInProgress() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        XCTAssertEqual(flush(session), [.flushed])

        let done = expectation(description: "migration answered")
        var failure: Error?
        session.performMigration(to: InMemoryStorageBackend(), strategy: .seedRemote) { result in
            if case .failure(let error) = result { failure = error }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(failure as? VaultSessionError, .quitInProgress)
    }

    // MARK: Stale write errors

    func testFailedWriteFollowedBySuccessfulSynchronousSaveDoesNotPromptAtQuit() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.failWrites(with: CocoaError(.fileWriteNoPermission))
        addEntry(session, title: "fixed-later")
        waitUntil { session.lastSaveError != nil }
        XCTAssertNotNil(session.lastSaveError)

        store.failWrites(with: nil)
        try session.save(password: password)
        XCTAssertEqual(flush(session), [.flushed], "the current state is on disk, so the older failure is stale")
        XCTAssertEqual(try titlesOnDisk(), ["fixed-later"])
    }

    func testFailedWriteFollowedByStoreSwapDoesNotPromptAtQuit() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        store.failWrites(with: CocoaError(.fileWriteNoPermission))
        addEntry(session, title: "moved")
        waitUntil { session.lastSaveError != nil }

        let newDirectory = directory.appendingPathComponent("moved-to")
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        session.updatePrimaryStore(VaultFileStore(directory: newDirectory))
        XCTAssertEqual(flush(session), [.flushed])
    }

    func testGenuineLatestFailureIsStillReportedAfterAnEarlierSynchronousSave() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: password)
        try session.save(password: password)
        store.failWrites(with: CocoaError(.fileWriteNoPermission))
        addEntry(session, title: "doomed")
        guard case .saveFailed = flush(session).first else { return XCTFail("a failure after the last good save must be reported") }
    }

    // MARK: Slow remote sync

    func testSlowRemoteSyncDoesNotHoldBackQuitOnceLocalWritesAreDurable() throws {
        let remote = GatedStorageBackend()
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let session = VaultSession(fileStore: store, syncEngine: syncEngine)
        try session.unlock(password: password)
        remote.holdWrites()
        defer { remote.releaseWrites() }
        addEntry(session, title: "local-first")

        let started = Date()
        let outcomes = flush(session, timeout: 5, patience: 4)
        XCTAssertEqual(outcomes, [.flushed], "the remote upload is atomic and retried on the next launch; it is not a reason to prompt")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "must not sit out the timeout for a sync that is not a local write")
        XCTAssertEqual(try titlesOnDisk(), ["local-first"])
    }
}

final class QuitFlushCoordinatorTests: XCTestCase {
    private final class FakeSession: VaultFlushing {
        var requestedTimeouts: [TimeInterval] = []
        var completions: [(VaultFlushOutcome) -> Void] = []
        private(set) var resumeCount = 0
        func flushPendingWrites(timeout: TimeInterval, completion: @escaping (VaultFlushOutcome) -> Void) {
            requestedTimeouts.append(timeout)
            completions.append(completion)
        }
        func resumeAfterCancelledQuit() { resumeCount += 1 }
    }

    private final class FakePrompter: QuitPrompting {
        var outcomes: [VaultFlushOutcome] = []
        var answers: [(Bool) -> Void] = []
        func confirmQuitAnyway(after outcome: VaultFlushOutcome, completion: @escaping (Bool) -> Void) {
            outcomes.append(outcome)
            answers.append(completion)
        }
    }

    func testNoSessionTerminatesImmediately() {
        let coordinator = QuitFlushCoordinator(session: nil, prompter: FakePrompter())
        XCTAssertEqual(coordinator.begin(reply: { _ in XCTFail("no reply expected") }), .terminateNow)
    }

    func testCleanFlushTerminatesWithoutPrompting() {
        let session = FakeSession(), prompter = FakePrompter()
        let coordinator = QuitFlushCoordinator(session: session, prompter: prompter, flushTimeout: 7)
        var replies: [Bool] = []
        XCTAssertEqual(coordinator.begin(reply: { replies.append($0) }), .terminateLater)
        XCTAssertEqual(session.requestedTimeouts, [7])
        session.completions[0](.flushed)
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(prompter.outcomes.isEmpty)
    }

    func testFailedFlushAsksAndCancelKeepsTheAppRunning() {
        let session = FakeSession(), prompter = FakePrompter()
        let coordinator = QuitFlushCoordinator(session: session, prompter: prompter)
        var replies: [Bool] = []
        _ = coordinator.begin(reply: { replies.append($0) })
        session.completions[0](.saveFailed("disk full"))
        XCTAssertEqual(prompter.outcomes, [.saveFailed("disk full")])
        XCTAssertTrue(replies.isEmpty, "no decision before the user answers")
        prompter.answers[0](false)
        XCTAssertEqual(replies, [false])

        // The app is still running, so a later quit attempt must work again.
        XCTAssertEqual(coordinator.begin(reply: { replies.append($0) }), .terminateLater)
    }

    func testTimeoutAsksAndQuitAnywayTerminates() {
        let session = FakeSession(), prompter = FakePrompter()
        let coordinator = QuitFlushCoordinator(session: session, prompter: prompter)
        var replies: [Bool] = []
        _ = coordinator.begin(reply: { replies.append($0) })
        session.completions[0](.timedOut)
        XCTAssertEqual(prompter.outcomes, [.timedOut])
        prompter.answers[0](true)
        XCTAssertEqual(replies, [true])
    }

    func testSecondQuitWhileOneIsInFlightIsDropped() {
        let session = FakeSession()
        let coordinator = QuitFlushCoordinator(session: session, prompter: FakePrompter())
        _ = coordinator.begin(reply: { _ in })
        XCTAssertEqual(coordinator.begin(reply: { _ in XCTFail("must not reply") }), .alreadyInFlight)
        XCTAssertEqual(session.completions.count, 1)
    }

    func testCancelResumesTheSessionAndQuitAnywayDoesNot() {
        let session = FakeSession(), prompter = FakePrompter()
        let coordinator = QuitFlushCoordinator(session: session, prompter: prompter)
        _ = coordinator.begin(reply: { _ in })
        session.completions[0](.timedOut)
        XCTAssertEqual(session.resumeCount, 0, "still asking: the freeze stays while the prompt is up")
        prompter.answers[0](false)
        XCTAssertEqual(session.resumeCount, 1)

        _ = coordinator.begin(reply: { _ in })
        session.completions[1](.saveFailed("disk full"))
        prompter.answers[1](true)
        XCTAssertEqual(session.resumeCount, 1, "quitting anyway must stay frozen until the process exits")
    }

    func testCleanFlushStaysFrozenForTheExit() {
        let session = FakeSession()
        let coordinator = QuitFlushCoordinator(session: session, prompter: FakePrompter())
        _ = coordinator.begin(reply: { _ in })
        session.completions[0](.flushed)
        XCTAssertEqual(session.resumeCount, 0)
    }

    func testDuplicateTerminationRequestWhileFlushInFlightIsDroppedThenWorksAfterCancel() {
        let session = FakeSession(), prompter = FakePrompter()
        let coordinator = QuitFlushCoordinator(session: session, prompter: prompter)
        var terminateCalls = 0

        // Nothing in flight: the request goes through (AppKit will then ask the delegate).
        XCTAssertTrue(coordinator.requestTermination { terminateCalls += 1 })
        XCTAssertEqual(terminateCalls, 1)

        // Cmd-Q is waiting on the flush; a takeover request or a menu bar click must not call
        // NSApp.terminate again (AppKit would exit without waiting for the flush).
        _ = coordinator.begin(reply: { _ in })
        XCTAssertTrue(coordinator.isInFlight)
        XCTAssertFalse(coordinator.requestTermination { terminateCalls += 1 })
        XCTAssertEqual(terminateCalls, 1)

        // The flush fails and the user cancels: the app runs on and quitting works again.
        session.completions[0](.timedOut)
        XCTAssertFalse(coordinator.requestTermination { terminateCalls += 1 }, "still in flight while the prompt is up")
        prompter.answers[0](false)
        XCTAssertFalse(coordinator.isInFlight)
        XCTAssertTrue(coordinator.requestTermination { terminateCalls += 1 })
        XCTAssertEqual(terminateCalls, 2)
    }

    func testDuplicateTerminationRequestEventuallyTerminatesAfterASuccessfulFlush() {
        let session = FakeSession()
        let coordinator = QuitFlushCoordinator(session: session, prompter: FakePrompter())
        var replies: [Bool] = []
        _ = coordinator.begin(reply: { replies.append($0) })
        XCTAssertFalse(coordinator.requestTermination { XCTFail("duplicate must be dropped") })
        session.completions[0](.flushed)
        XCTAssertEqual(replies, [true], "the one pending quit still completes")
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testCancelIsTheDefaultButton() {
        XCTAssertEqual(AppKitQuitPrompter.buttonTitles, ["Cancel", "Quit Anyway"])
    }
}
