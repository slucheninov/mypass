import Foundation
import MyPassKit
import SyncKit

enum VaultState {
    case locked
    case unlocked(KdbxDatabase)
}

extension VaultState: Equatable {
    static func == (lhs: VaultState, rhs: VaultState) -> Bool {
        switch (lhs, rhs) {
        case (.locked, .locked): return true
        case (.unlocked, .unlocked): return true
        default: return false
        }
    }
}

enum VaultSessionError: Error {
    case notUnlocked
    case quitInProgress
}

/// How a quit-time flush ended. `saveFailed` carries `lastSaveError` as it
/// stood after every earlier write finished, so a failure is never hidden.
enum VaultFlushOutcome: Equatable {
    case flushed
    case saveFailed(String)
    case timedOut
}

protocol VaultFlushing: AnyObject {
    func flushPendingWrites(timeout: TimeInterval, completion: @escaping (VaultFlushOutcome) -> Void)
    /// Ends the quit-time freeze that `flushPendingWrites` started, after the quit was cancelled.
    func resumeAfterCancelledQuit()
}

final class VaultSession: ObservableObject, VaultFlushing {
    @Published private(set) var state: VaultState = .locked
    @Published private(set) var lastSaveError: String?

    /// `true` when the configured primary location is iCloud Drive but its
    /// bookmark could not be resolved at launch (see
    /// `VaultPrimaryStoreResolver`), so `fileStore` is actually the Local
    /// fallback rather than the real iCloud store — possibly a stale copy
    /// from before the user switched to iCloud. `VaultLocationSettingsPane`
    /// reads this to warn instead of claiming "iCloud Drive" is active, and
    /// offers the existing "Switch to iCloud Drive…" flow to recover.
    /// Cleared whenever `updatePrimaryStore` runs, since that only ever
    /// happens with a store that already resolved successfully.
    @Published private(set) var iCloudPrimaryFallbackActive: Bool

    /// `true` when the configured primary is a bookmarked local `.kdbx` file
    /// (`localVaultFileBookmark`, set by "Open Existing…") but its bookmark
    /// could not be resolved at launch (see `VaultPrimaryStoreResolver`), so
    /// `fileStore` is actually the Application Support default rather than
    /// the file the user actually opened. The local-bookmark counterpart to
    /// `iCloudPrimaryFallbackActive` — kept as a separate flag (rather than
    /// folding into that one) since the user-facing warning text differs and
    /// the two failure modes are unrelated. Cleared whenever
    /// `updatePrimaryStore` runs, for the same reason
    /// `iCloudPrimaryFallbackActive` is.
    @Published private(set) var localFileFallbackActive: Bool

    private var fileStore: VaultPrimaryStorage

    /// Optional remote sync orchestrator (Phase 3). `nil` for sessions that
    /// only ever use local storage — every existing Phase 2 call site keeps
    /// compiling and behaving unchanged via the default parameter below.
    private let syncEngine: SyncEngine?

    /// Retained for the lifetime of the unlocked session so every mutation can be
    /// autosaved without re-prompting the user. Wiped on `lock()`.
    private var sessionPassword: String?

    /// Dedicated *serial* background queue for `persist(_:)`'s KDF derivation +
    /// disk write. A concurrent queue would let two back-to-back `persist`
    /// calls race to completion in either order — e.g. a rapid second
    /// `mutate()` could finish its background save before the first one does,
    /// and the (now-stale) first save would then overwrite it, permanently
    /// losing the second mutation on disk even though in-memory state was
    /// correct. Serializing here guarantees writes land in invocation order.
    private let persistQueue = DispatchQueue(label: "com.mypass.vaultsession.persist", qos: .userInitiated)

    /// Coalesces rapid `touchAccess` calls into a single debounced persist.
    private var touchAccessPersistWorkItem: DispatchWorkItem?

    /// The bytes last successfully written to `fileStore` by `persist(_:)`,
    /// tracked for downstream consumers that need last-known-good ciphertext
    /// (e.g. a future remote-change reload comparing against what's on disk).
    /// NOT used to decide whether to skip a write — `KdbxDatabase.save`
    /// mints fresh random KDF salt/IV/inner-stream-key material on every
    /// call, so two serializations of logically-identical content are
    /// essentially never byte-identical; see `lastSuccessfullyWrittenDatabase`
    /// for the actual skip check. Read and written *only* from `persistQueue`
    /// (inside `persist(_:)`'s background closure) to avoid a data race; the
    /// main-thread seed points (`unlock`, `save(password:)`, `syncOnUnlock`)
    /// go through `recordSuccessfulWrite(_:database:)`, which hops onto the
    /// same serial queue via `sync` rather than assigning the property directly.
    private var lastSuccessfullyWrittenBytes: Data?

    /// The logical content (group tree + tombstones + recycle-bin reference)
    /// last successfully written to `fileStore`. `persist(_:)` compares its
    /// freshly-mutated snapshot against this — via `KdbxDatabase`'s
    /// `Equatable` conformance, which recurses through `rootGroup`'s entries
    /// and subgroups — rather than against serialized bytes, so a no-op
    /// persist (nothing actually changed) is correctly detected even though
    /// re-serializing would always produce different ciphertext. Always a
    /// deep copy, never a reference into live session state: `KdbxGroup` is a
    /// class, so storing the session's actual `rootGroup` here would let a
    /// later in-place `mutate()` silently mutate this "last written" snapshot
    /// too, making every subsequent comparison spuriously equal. Same
    /// threading contract as `lastSuccessfullyWrittenBytes` — `persistQueue`
    /// only, seeded from the main thread via `recordSuccessfulWrite(_:database:)`.
    private var lastSuccessfullyWrittenDatabase: KdbxDatabase?

    /// `true` whenever in-memory state has changed since the last write
    /// reached `fileStore`. Set on the main thread by `mutate` and cleared on
    /// the main thread by `persist(_:)`'s completion handlers (via
    /// `DispatchQueue.main.async`), so — unlike the two properties above —
    /// it never needs a lock: every read and write happens on the main
    /// thread. Backs `triggerBackgroundSyncIfDirty()`, which the app-level
    /// timer calls instead of unconditionally syncing every tick.
    private var hasDirtyLocalChanges = false

    /// Bookkeeping for the quit-time flush, all guarded by `writeStateLock` because the
    /// queued writes report from `persistQueue` while the flush runs on the main thread.
    ///
    /// - `pendingLocalWrites` counts queue jobs that may still write the local file (an
    ///   autosave, a debounced touch, a migration), from the moment they are enqueued until
    ///   their LOCAL step is done. A remote sync that follows a finished local write is
    ///   deliberately not counted: the data is already durable, the upload is atomic and the
    ///   next launch syncs again, so the quit must not wait on (or prompt about) it.
    /// - `queuedWriteError` is the failure of the newest local write, or `nil` when the newest
    ///   one reached `fileStore` (or needed no write). A failed remote sync after a successful
    ///   local write is NOT recorded here.
    /// - Generations order those writes against synchronous saves on the main thread
    ///   (`save(password:)`, the merge in `syncOnUnlock`, a store swap). A synchronous save
    ///   writes the whole current state, so it supersedes every queued failure of an older
    ///   generation, whether that failure was already recorded or lands later.
    private let writeStateLock = NSLock()
    private var queuedWriteError: String?
    private var pendingLocalWrites = 0
    private var writeGeneration = 0
    private var supersededThroughGeneration = 0
    private var localDrainWaiters: [(String?) -> Void] = []

    private enum LocalWriteResult {
        case wrote
        case failed(String)
        /// The job did not touch the local file (a failed migration, a probe).
        case unchanged
    }

    /// Main thread, at enqueue time, so a flush that starts right afterwards already sees the job.
    private func beginLocalWrite() -> Int {
        writeStateLock.lock()
        defer { writeStateLock.unlock() }
        pendingLocalWrites += 1
        writeGeneration += 1
        return writeGeneration
    }

    /// `persistQueue`. Exactly once per `beginLocalWrite()`.
    private func finishLocalWrite(generation: Int, result: LocalWriteResult) {
        writeStateLock.lock()
        switch result {
        case .wrote:
            queuedWriteError = nil
        case .failed(let message):
            if generation > supersededThroughGeneration { queuedWriteError = message }
        case .unchanged:
            break
        }
        pendingLocalWrites -= 1
        var waiters: [(String?) -> Void] = []
        let error = queuedWriteError
        if pendingLocalWrites == 0 {
            waiters = localDrainWaiters
            localDrainWaiters = []
        }
        writeStateLock.unlock()
        waiters.forEach { $0(error) }
    }

    /// Any thread. The current state just reached `fileStore` outside the queue (or no longer
    /// has anything to write), so an earlier queued failure is stale and must not prompt at quit.
    private func noteSynchronousDurableWrite() {
        writeStateLock.lock()
        writeGeneration += 1
        supersededThroughGeneration = writeGeneration
        queuedWriteError = nil
        writeStateLock.unlock()
    }

    /// Calls `waiter` (on whatever thread finishes the last local write, or immediately on the
    /// caller's thread when none is pending) with the newest local write error.
    private func whenLocalWritesDrained(_ waiter: @escaping (String?) -> Void) {
        writeStateLock.lock()
        if pendingLocalWrites == 0 {
            let error = queuedWriteError
            writeStateLock.unlock()
            waiter(error)
            return
        }
        localDrainWaiters.append(waiter)
        writeStateLock.unlock()
    }

    /// `true` from the moment the quit-time flush starts until the quit is cancelled. While it
    /// is set the session accepts no new change: `mutate` returns `false`, `touchAccess` and
    /// background sync do nothing and a migration fails with `VaultSessionError.quitInProgress`.
    /// Everything accepted before it was set is already queued and is waited for; everything
    /// after it is refused explicitly, so no change is acknowledged and then lost to the exit.
    /// Published so the windows and the menu bar panel can show "saving" and disable their
    /// controls (`QuitFreezeOverlay`) instead of silently dropping what the user types.
    /// Main thread only.
    @Published private(set) var isQuitInProgress = false

    /// `true` while a debounced `touchAccess` persist is still waiting to run.
    /// Exposed so tests can assert that starting a migration cancels it.
    var hasPendingTouchAccessPersist: Bool {
        guard let touchAccessPersistWorkItem else { return false }
        return !touchAccessPersistWorkItem.isCancelled
    }

    init(
        fileStore: VaultPrimaryStorage,
        syncEngine: SyncEngine? = nil,
        iCloudPrimaryFallbackActive: Bool = false,
        localFileFallbackActive: Bool = false
    ) {
        self.fileStore = fileStore
        self.syncEngine = syncEngine
        self.iCloudPrimaryFallbackActive = iCloudPrimaryFallbackActive
        self.localFileFallbackActive = localFileFallbackActive
        wireRemoteChangeHandler(on: fileStore)
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
    }

    /// The primary store currently backing this session, snapshotted before a
    /// location-change migration starts — `VaultLocationChangeSheet` holds
    /// onto it as "the old location" so it knows what to delete once the new
    /// location has been verified. Read-only: mutate via `updatePrimaryStore`.
    var currentPrimaryStore: VaultPrimaryStorage { fileStore }

    var primaryVaultPathDisplay: String {
        fileStore.primaryVaultFileURL?.path ?? String(localized: "Path unavailable", comment: "Vault settings: shown instead of the vault file path when there is none")
    }

    func loadVaultData() throws -> Data? {
        try fileStore.load()
    }

    func unlock(password: String) throws {
        if let existingData = try fileStore.load() {
            let db = try KdbxDatabase.open(data: existingData, password: password)
            state = .unlocked(db)
            sessionPassword = password
            recordSuccessfulWrite(existingData, database: db)
            state = .unlocked(syncOnUnlock(db, password: password))
        } else {
            let now = Date()
            let rootGroup = KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: now,
                lastModificationTime: now,
                locationChanged: now,
                entries: [],
                subgroups: []
            )
            let db = KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
            state = .unlocked(db)
            try save(password: password)
            sessionPassword = password
            state = .unlocked(syncOnUnlock(db, password: password))
        }
    }

    func lock() {
        touchAccessPersistWorkItem?.cancel()
        touchAccessPersistWorkItem = nil
        state = .locked
        sessionPassword = nil
    }

    /// Swaps the primary store the session reads/writes from — used when the
    /// user changes the configured vault location. Callers are responsible for
    /// having already migrated any existing data to the new store (see
    /// `VaultLocationChangeSheet`); this method only changes where subsequent
    /// `unlock`/`persist` calls point.
    ///
    /// Also invalidates `persist(_:)`'s logical-equality skip state
    /// (`lastSuccessfullyWrittenBytes`/`lastSuccessfullyWrittenDatabase`):
    /// that state records what content is already durably written to the
    /// *previous* `fileStore`, which says nothing about the new one — without
    /// clearing it, a swap to a store that doesn't yet have the current
    /// content (the common case) would still compare the next persist's
    /// snapshot against the stale "already written" record, see them as
    /// logically equal, and wrongly skip writing to the new store entirely.
    ///
    /// Also clears the secondary `.folder`/`.sftp` `SyncEngine` checkpoints
    /// (see `SyncBackendResolver.clearCheckpoint`): a checkpoint records the
    /// remote's last-known modification date for whatever vault was
    /// previously primary, and every call site that swaps the primary store
    /// — the regular Move flow, and `retargetToOpenExistingVault`'s switch to
    /// a completely unrelated `.kdbx` — points `fileStore` at content that
    /// may be entirely different from what the checkpoint was taken against.
    /// Trusting a stale checkpoint after a primary swap risks `SyncEngine`
    /// either overwriting the secondary remote with the newly-primary vault's
    /// unrelated data, or merging the OLD vault's entries into the new one.
    /// Centralized here (rather than left to each call site to remember)
    /// specifically so every future primary-swap site inherits the guard
    /// automatically. Never runs during normal app-launch resolution — the
    /// resolver builds `VaultSession` directly via `init`, not this method —
    /// so a checkpoint that's still valid at launch is never needlessly
    /// cleared.
    func updatePrimaryStore(_ newStore: VaultPrimaryStorage) {
        fileStore = newStore
        iCloudPrimaryFallbackActive = false
        localFileFallbackActive = false
        wireRemoteChangeHandler(on: newStore)
        persistQueue.sync {
            self.lastSuccessfullyWrittenBytes = nil
            self.lastSuccessfullyWrittenDatabase = nil
        }
        // A write that failed against the previous store says nothing about the new one.
        noteSynchronousDurableWrite()
        SyncBackendResolver.clearCheckpoint(for: .folder)
        SyncBackendResolver.clearCheckpoint(for: .sftp)
    }

    /// Design spec's external-change handling: reload (Last-Writer-Wins, not
    /// push) when another device/process touches the same iCloud Drive file.
    /// Wired centrally here — both at `init` and on every later
    /// `updatePrimaryStore` swap — so an in-session switch to iCloud
    /// (`VaultLocationChangeSheet`) keeps working without every call site
    /// having to remember to re-wire it. A `.local` store is a no-op since
    /// `VaultFileStore` has no such notification.
    private func wireRemoteChangeHandler(on store: VaultPrimaryStorage) {
        guard let iCloudStore = store as? ICloudDriveVaultStore else { return }
        iCloudStore.onRemoteChange = { [weak self] in
            self?.reloadPrimaryFromRemoteIfChanged()
        }
    }

    /// Reloads in-memory state from whatever the newest available bytes are
    /// at `fileStore` (Last-Writer-Wins), instead of pushing local state up —
    /// the old `wireRemoteChangeHandler` wiring called `triggerBackgroundSync()`
    /// here, which this replaces. Runs the coordinated iCloud read + KDF
    /// derivation on `persistQueue`, same as `persist(_:)`, so it cannot
    /// interleave with an autosave or another reload. No-op when locked, when
    /// there is no session password to open the remote bytes with, or when
    /// `fileStore` isn't backed by iCloud (the Local backend has no
    /// remote-change notion at all, so it never calls this).
    func reloadPrimaryFromRemoteIfChanged() {
        guard case .unlocked = state, let password = sessionPassword else { return }
        guard let iCloudStore = fileStore as? ICloudDriveVaultStore else { return }
        persistQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let remoteBytes = try iCloudStore.loadNewestBytes() else { return }

                // Cheap short-circuit BEFORE paying for a KDF derivation:
                // if the remote bytes are byte-identical to what this
                // session itself last wrote, this notification is just an
                // echo of our own write (or a re-notification of a file
                // nothing has touched) — skip decode and `state` replacement
                // entirely. This matters beyond performance: KDBX dates
                // round-trip at whole-second precision (see
                // `KdbxXmlCoder`'s `Int64(date.timeIntervalSince1970.rounded())`),
                // while `lastSuccessfullyWrittenDatabase` below is seeded
                // from a full-precision in-memory snapshot (`Date()` at
                // `mutate`/`touchAccess` time) — so the logical-equality
                // check further down essentially never matches even when
                // content is genuinely unchanged, and without this
                // byte-level check first, every remote-change notification
                // would decode and republish `state`. Safe to read
                // `lastSuccessfullyWrittenBytes` here: we're on
                // `persistQueue`, the only queue that ever touches it.
                if remoteBytes == self.lastSuccessfullyWrittenBytes { return }

                let decodedDatabase = try KdbxDatabase.open(data: remoteBytes, password: password)

                // Fallback for when bytes differ but content doesn't — e.g.
                // iCloud re-uploaded/re-synced the file (fresh KDF salt/IV),
                // or the precision mismatch described above happens to
                // matter for this particular comparison. Compared as
                // `KdbxDatabase` values (logical content), NOT as
                // serialized bytes: `save(password:cipher:compression:)`
                // mints fresh random KDF salt/IV/inner-stream-key material on
                // every call, so two serializations of identical content are
                // essentially never byte-identical — a raw-bytes comparison
                // here would almost never detect "nothing actually changed"
                // and would instead reload+republish on every remote-change
                // notification, including ones caused by this device's own
                // writes. Safe to read `lastSuccessfullyWrittenDatabase` here:
                // we're on `persistQueue`, the only queue that ever touches it.
                if decodedDatabase == self.lastSuccessfullyWrittenDatabase {
                    return
                }

                // Deep-copy before storing as the new "last written" snapshot,
                // same reason `recordSuccessfulWrite`/`persist(_:)` do:
                // `KdbxGroup` is a class, so storing `decodedDatabase`'s own
                // `rootGroup` here (rather than a copy) would let a later
                // in-place `mutate()` on the live `state` silently mutate this
                // snapshot too, making every subsequent comparison spuriously
                // equal.
                let snapshot = KdbxDatabase(
                    rootGroup: decodedDatabase.rootGroup.deepCopy(),
                    deletedObjects: decodedDatabase.deletedObjects,
                    recycleBinGroupUUID: decodedDatabase.recycleBinGroupUUID
                )
                self.lastSuccessfullyWrittenBytes = remoteBytes
                self.lastSuccessfullyWrittenDatabase = snapshot
                // The session is about to hold exactly what is on disk, so an older queued failure is stale.
                self.noteSynchronousDurableWrite()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hasDirtyLocalChanges = false
                    self.lastSaveError = nil
                    // Only replace state if still unlocked — if the user
                    // called lock() while this reload was in flight, don't
                    // silently re-unlock the vault (same guard
                    // `performMigration`'s completion handler uses).
                    if case .unlocked = self.state {
                        self.state = .unlocked(decodedDatabase)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = String(localized: "Could not reload vault from iCloud: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
                }
            }
        }
    }

    /// Checks `password` against the vault currently on disk at `fileStore`,
    /// without mutating `state` or `sessionPassword` — used to gate a settings
    /// change (e.g. changing the vault location) behind proof of ownership
    /// without disturbing an in-progress unlocked session or its unsaved edits.
    /// Returns `false` (never throws) for a wrong password, a corrupt file, or
    /// when no vault exists yet at the current location.
    func verifyPassword(_ password: String) -> Bool {
        guard let data = (try? fileStore.load()) ?? nil else { return false }
        return (try? KdbxDatabase.open(data: data, password: password)) != nil
    }

    /// Confirms `data` (bytes just written to a location-change destination)
    /// opens with the password already proven for this session, without
    /// exposing that password to the caller — used by
    /// `VaultLocationChangeSheet` to gate deleting the old location's file on
    /// the new location genuinely being readable. Throws
    /// `VaultSessionError.notUnlocked` if there is no session password to
    /// verify against (should not happen: migration itself requires one).
    func verifyDestinationOpens(data: Data) throws {
        guard let sessionPassword else { throw VaultSessionError.notUnlocked }
        try VaultLocationMoveSupport.verifyDestinationOpens(data: data, password: sessionPassword)
    }

    func save(password: String) throws {
        guard case .unlocked(let db) = state else {
            throw VaultSessionError.notUnlocked
        }
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        try fileStore.save(data: data)
        recordSuccessfulWrite(data, database: db)
        noteSynchronousDurableWrite()
    }

    /// Applies `body` and queues the save. Returns `false`, without running `body`, when the
    /// vault is locked or a quit is in progress (see `isQuitInProgress`); callers that
    /// acknowledge the change to someone else (the extension bridge) must not do so then.
    @discardableResult
    func mutate(_ body: (inout KdbxDatabase) -> Void) -> Bool {
        guard !isQuitInProgress, case .unlocked(var db) = state else { return false }
        body(&db)
        state = .unlocked(db)
        hasDirtyLocalChanges = true
        persist(db)
        return true
    }

    /// Leaves the quit-time freeze after the user cancelled the quit. Nothing was lost by
    /// freezing: the debounced touch was written when the flush started.
    func resumeAfterCancelledQuit() {
        isQuitInProgress = false
    }

    /// Quit-time flush. Writes the debounced `touchAccess` change now (if the
    /// vault is still unlocked), freezes the session (`isQuitInProgress`: every
    /// change accepted so far is queued, later ones are refused), then waits for
    /// every queued LOCAL write — INCLUDING writes queued before the session was
    /// locked, which keep running after `lock()` because each one captured its
    /// own snapshot and password. Must be called on the main thread. Completes on
    /// the main thread, exactly once, with the first of: the local writes done
    /// (`flushed`, or `saveFailed` when the newest local write failed) or
    /// `timeout` elapsing (`timedOut`).
    ///
    /// A remote sync that follows a finished local write is not waited for (see
    /// `pendingLocalWrites`). The freeze outlives the completion on purpose — it
    /// covers the window up to the exit and the "Quit Anyway" prompt — and ends
    /// only through `resumeAfterCancelledQuit()`.
    ///
    /// Never blocks the main thread, and deliberately does NOT rely on
    /// `DispatchQueue.main`: during `applicationShouldTerminate` ->
    /// `.terminateLater` AppKit waits inside a nested run loop, and when
    /// `NSApp.terminate` was itself reached from a main-queue block (for
    /// example a notification callback) libdispatch will not run further
    /// main-queue blocks until that block returns — a reply scheduled with
    /// `DispatchQueue.main` would never fire (measured with a real
    /// `terminateLater`). The completion hop and the timeout therefore use
    /// run-loop sources, which a nested run loop does service.
    ///
    /// A locked session cannot write a debounced change that `lock()` already
    /// cancelled; only the queued writes remain to wait for.
    func flushPendingWrites(timeout: TimeInterval, completion: @escaping (VaultFlushOutcome) -> Void) {
        if let pending = touchAccessPersistWorkItem {
            pending.cancel()
            touchAccessPersistWorkItem = nil
            if case .unlocked(let db) = state { persist(db) }
        }
        // After the debounced touch above has been queued and before anything else can run on
        // the main thread: every change accepted so far is queued, none is accepted from now on.
        isQuitInProgress = true

        var finished = false
        var timeoutTimer: Timer?
        let finish: (VaultFlushOutcome) -> Void = { outcome in
            guard !finished else { return }
            finished = true
            timeoutTimer?.invalidate()
            completion(outcome)
        }
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in finish(.timedOut) }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        whenLocalWritesDrained { error in
            let outcome: VaultFlushOutcome = error.map(VaultFlushOutcome.saveFailed) ?? .flushed
            let mainRunLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { finish(outcome) }
            CFRunLoopWakeUp(mainRunLoop)
        }
    }

    /// Runs `triggerBackgroundSync()` only when there are unwritten local
    /// changes — called by the app-level background sync timer so a tick
    /// that finds nothing dirty doesn't pay for a KDF derivation and a
    /// same-bytes disk write just to discover there was nothing to do.
    /// Callers that need an unconditional resync regardless of local dirty
    /// state (e.g. an external-change notification from iCloud or a local
    /// folder watcher) should keep calling `triggerBackgroundSync()` directly.
    func triggerBackgroundSyncIfDirty() {
        guard hasDirtyLocalChanges else { return }
        triggerBackgroundSync()
    }

    /// Bumps `lastAccessTime` for the entry in the live group tree and
    /// schedules a debounced background persist. Does not republish `@Published`
    /// state — avoids List/detail re-render feedback loops on access tracking.
    /// No-op when vault is locked or entry ID is not found.
    func touchAccess(entryID: UUID) {
        guard !isQuitInProgress, case .unlocked(let db) = state else { return }
        guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: db.rootGroup) else { return }
        var entry = location.group.entries[location.index]
        entry.lastAccessTime = Date()
        location.group.entries[location.index] = entry

        touchAccessPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .unlocked(let currentDB) = self.state else { return }
            self.persist(currentDB)
        }
        touchAccessPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    /// Runs a sync pass without an accompanying local mutation — used by
    /// external-change notifications (Task 3's `LocalFolderChangeWatcher`
    /// for the Local backend, `iCloudBackend.onRemoteChange` for the iCloud
    /// backend, both wired in `MyPassApp.init()`, Task 12) and by a manual
    /// "Sync Now" affordance in Settings (Task 12/13), so a remote change
    /// made on another device is picked up promptly instead of waiting for
    /// the next unlock or local edit. Reuses the existing serial
    /// `persistQueue` + `syncEngine.sync(...)` pipeline via `persist(_:)` —
    /// re-saving byte-identical content locally when nothing actually
    /// changed is harmless (`VaultFileStore.save` overwrites idempotently)
    /// and keeps this a single well-tested code path rather than a second,
    /// parallel one.
    func triggerBackgroundSync() {
        guard !isQuitInProgress, case .unlocked(let db) = state else { return }
        persist(db)
    }

    /// Reports what a candidate remote currently holds, so the connect flow can
    /// offer the right reconciliation strategies. Runs on `persistQueue` because
    /// probing an iCloud folder performs a coordinated read that can block for
    /// the download timeout, and completes on the main queue.
    func probeMigrationTarget(
        remote: StorageBackend,
        completion: @escaping (Result<VaultMigrationTargetProbe, Error>) -> Void
    ) {
        guard case .unlocked = state, sessionPassword != nil else {
            DispatchQueue.main.async { completion(.failure(VaultMigrationError.vaultLocked)) }
            return
        }
        let service = VaultMigrationService(fileStore: fileStore)
        persistQueue.async {
            let result = Result { try service.probe(remote: remote) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Connects this vault to `remote` using `strategy`. Must be called from the
    /// main thread: preconditions and the debounce cancellation happen
    /// synchronously, then the Argon2id derivations and remote I/O run on
    /// `persistQueue` so migration cannot interleave with an autosave or a
    /// background sync pass. When the strategy replaced the local database, the
    /// published state is updated on the main queue before `completion` runs, so
    /// the UI never shows stale entries.
    func performMigration(
        to remote: StorageBackend,
        strategy: VaultMigrationStrategy,
        completion: @escaping (Result<VaultMigrationOutcome, Error>) -> Void
    ) {
        guard !isQuitInProgress else {
            DispatchQueue.main.async { completion(.failure(VaultSessionError.quitInProgress)) }
            return
        }
        guard case .unlocked(let db) = state, let password = sessionPassword else {
            DispatchQueue.main.async { completion(.failure(VaultMigrationError.vaultLocked)) }
            return
        }

        touchAccessPersistWorkItem?.cancel()
        touchAccessPersistWorkItem = nil

        // Same deep copy `persist(_:)` takes: the background work must not see
        // the live, still-mutable group tree.
        let snapshot = KdbxDatabase(
            rootGroup: db.rootGroup.deepCopy(),
            deletedObjects: db.deletedObjects,
            recycleBinGroupUUID: db.recycleBinGroupUUID
        )
        let service = VaultMigrationService(fileStore: fileStore)

        let generation = beginLocalWrite()
        persistQueue.async { [weak self] in
            let result = Result {
                try service.migrate(
                    local: snapshot,
                    password: password,
                    remote: remote,
                    strategy: strategy
                )
            }
            var wroteLocally = false
            if case .success(let outcome) = result, outcome.mergedDatabase != nil { wroteLocally = true }
            self?.finishLocalWrite(generation: generation, result: wroteLocally ? .wrote : .unchanged)
            DispatchQueue.main.async { [weak self] in
                if case .success(let outcome) = result, let mergedDatabase = outcome.mergedDatabase {
                    // Only apply the merged database if the session is still unlocked.
                    // If the user called lock() while the migration was running,
                    // don't silently re-unlock the vault.
                    if case .unlocked = self?.state {
                        self?.state = .unlocked(mergedDatabase)
                    }
                }
                completion(result)
            }
        }
    }

    /// Retargets this session's primary vault to an existing `.kdbx` file the
    /// user picked via "Open Existing…" (`EntryListView`/`UnlockView`,
    /// `OpenExistingVaultSheet`). `database` must already have been opened
    /// with `password` against the bytes at `fileURL` — this method never
    /// verifies the password itself, only wires up the new location and
    /// publishes what the caller already proved openable.
    ///
    /// Persists the switch to `defaults`: sets `"vaultLocation"` to `.local`,
    /// stores `bookmarkData` under `SyncBackendResolver.localVaultFileBookmarkKey`
    /// so `VaultPrimaryStoreResolver` reopens the same file on next launch,
    /// and clears `SyncBackendResolver.iCloudFolderBookmarkKey` — leaving a
    /// stale iCloud bookmark around would let a later resolver run treat the
    /// abandoned iCloud folder as still primary.
    ///
    /// Deletes the Application Support vault only when the *previous* primary
    /// was the plain default `VaultFileStore` with no file bookmark recorded
    /// (i.e. the user was on the untouched default local vault, not one they
    /// already retargeted once, and not iCloud) — that snapshot must be taken
    /// from `defaults`/`fileStore` *before* `updatePrimaryStore` runs, since
    /// this method itself is about to overwrite both. Deleting in any other
    /// case would destroy a vault that isn't a throwaway default (e.g. the
    /// iCloud copy, or a previously-opened external file).
    ///
    /// Ordering follows the same "commit first, delete-the-old-copy last and
    /// non-fatally" contract `VaultLocationChangeSheet.applyLocationChange`
    /// already established for its own old-location cleanup: every mutation
    /// that actually switches the live session onto the new vault
    /// (`updatePrimaryStore`, the `defaults` writes, publishing `state` and
    /// `sessionPassword`, seeding the write-tracking snapshot) runs first and
    /// unconditionally, and only the very last step — deleting the old
    /// Application Support vault file — can fail without rolling any of that
    /// back. That failure is caught and reported back to the caller as a
    /// non-nil warning instead of thrown, so `fileStore`/`defaults` and
    /// `state`/`sessionPassword` can never disagree about which vault is
    /// current: by the time deletion is attempted, the retarget itself has
    /// unconditionally already succeeded.
    ///
    /// Returns `nil` on a fully clean retarget, or a user-displayable warning
    /// string when the retarget itself succeeded but the old Application
    /// Support vault file could not be removed (permissions, transient IO,
    /// etc.) — mirroring how `VaultLocationChangeSheet` turns the same class
    /// of failure into a warning-flavored `successMessage` rather than an
    /// error. Also published via `lastSaveError` (not just returned) so it
    /// surfaces through the same "Save Error" alert `ContentView` already
    /// wires up regardless of which caller triggered this — important
    /// because `UnlockView`'s own call site is about to be swapped out for
    /// the unlocked `NavigationSplitView` the instant `state` above flips to
    /// `.unlocked`, so a warning only handed back to `UnlockView` itself
    /// would never actually be shown.
    @discardableResult
    func retargetToOpenExistingVault(
        fileURL: URL,
        bookmarkData: Data,
        password: String,
        database: KdbxDatabase,
        defaults: UserDefaults = .standard,
        localBackupDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPass")
            .appendingPathComponent("backups")
    ) throws -> String? {
        let newStore = try LocalFileVaultStore(bookmarkData: bookmarkData, localBackupDirectory: localBackupDirectory)
        // A missing `"vaultLocation"` value (fresh install, never touched
        // Settings) counts as default local too — `VaultLocationResolver`
        // resolves a `nil` raw value to `.local`, and this check needs the
        // same "what location is actually in effect" semantics rather than
        // a literal string match against an unset key.
        let oldStore = fileStore
        let wasDefaultLocal = oldStore is VaultFileStore
            && defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey) == nil
            && VaultLocationResolver.resolveVaultLocation(rawValue: defaults.string(forKey: "vaultLocation")) == .local

        updatePrimaryStore(newStore)
        defaults.set(VaultLocationOption.local.rawValue, forKey: "vaultLocation")
        defaults.set(bookmarkData, forKey: SyncBackendResolver.localVaultFileBookmarkKey)
        defaults.removeObject(forKey: SyncBackendResolver.iCloudFolderBookmarkKey)

        state = .unlocked(database)
        sessionPassword = password
        hasDirtyLocalChanges = false

        // Record what's already durably on disk at `fileURL` as this
        // session's "last successfully written" snapshot, via the same
        // `recordSuccessfulWrite` path `unlock`/`save(password:)`/
        // `syncOnUnlock` use — so `persist(_:)`'s logical-equality skip check
        // (see `lastSuccessfullyWrittenDatabase`'s doc comment) has a correct
        // baseline immediately, instead of writing a byte-identical copy
        // right back on the very next autosave. Deliberately does NOT write
        // these bytes to `newStore`: the file the user picked already
        // contains content that opened successfully with `password`, so
        // there is nothing to persist yet, only tracking state to seed.
        //
        // `try?`, not `try`: everything above this point has already
        // unconditionally committed the retarget (`updatePrimaryStore`,
        // `defaults`, `state`, `sessionPassword`), so a failure here — e.g.
        // an unrelated serialization error — must not make the whole method
        // throw and mislead the caller into showing "could not switch to
        // this vault" for a switch that already fully succeeded. Losing this
        // seed is a safe, minor degradation: the next real persist just does
        // an actual write instead of skipping one that would have been a
        // no-op anyway.
        if let data = try? database.save(password: password, cipher: .aes256, compression: .gzip) {
            recordSuccessfulWrite(data, database: database)
        }

        guard wasDefaultLocal else { return nil }

        // Safety check: if the old and new files are actually the same file
        // (e.g. user picked the default App Support vault via Open Existing),
        // skip deletion entirely — there's nothing to clean up, the locations
        // are just identical.
        if VaultLocationMoveSupport.isSameVaultFile(oldStore.primaryVaultFileURL, newStore.primaryVaultFileURL) {
            return nil
        }

        // Last step, warning-only: everything above has already committed,
        // so a failure here must never be allowed to make this method throw
        // and leave the caller thinking the retarget itself failed.
        do {
            // Delete via the captured `oldStore` instance itself (not a
            // freshly reconstructed `VaultFileStore` pointed at the real
            // system Application Support directory) so this operates on
            // whatever directory that store was actually configured with —
            // the production default (`MyPassApp`'s real App Support path)
            // and a test double pointed at a temp directory both work
            // correctly, rather than only the former.
            try oldStore.deleteVaultFileIfPresent()
            return nil
        } catch {
            let warning: String
            if let path = oldStore.primaryVaultFileURL?.path {
                warning = String(localized: "The vault was switched, but the old copy at \(path) could not be removed.", comment: "Save error alert; the argument is a file path")
            } else {
                warning = String(localized: "The vault was switched, but the old copy could not be removed.", comment: "Save error alert")
            }
            lastSaveError = warning
            return warning
        }
    }

    /// Dismisses a surfaced save-error alert without affecting vault state.
    func acknowledgeSaveError() {
        lastSaveError = nil
    }

    /// Runs one `SyncEngine.sync(...)` pass (if a `syncEngine` is attached)
    /// right after unlocking, so a merge made on another device is picked up
    /// as soon as the vault opens rather than only at the next mutation.
    /// Returns `db` unchanged when there is no `syncEngine`, or when sync
    /// itself fails — the local database the user already unlocked must
    /// remain usable even if the network round-trip does not succeed.
    private func syncOnUnlock(_ db: KdbxDatabase, password: String) -> KdbxDatabase {
        guard let syncEngine else { return db }
        let result: SyncResult
        do {
            result = try syncEngine.sync(local: db, password: password, cipher: .aes256, compression: .gzip)
        } catch {
            lastSaveError = String(localized: "Failed to sync vault: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
            return db
        }
        guard case .merged(let mergedDatabase) = result else { return db }
        do {
            let data = try mergedDatabase.save(password: password, cipher: .aes256, compression: .gzip)
            try fileStore.save(data: data)
            recordSuccessfulWrite(data, database: mergedDatabase)
            noteSynchronousDurableWrite()
        } catch {
            lastSaveError = String(localized: "Failed to save merged changes locally: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
        }
        return mergedDatabase
    }

    /// Seeds/updates `lastSuccessfullyWrittenBytes`/`lastSuccessfullyWrittenDatabase`
    /// from a write that just succeeded on the *main* thread (`unlock`,
    /// `save(password:)`, `syncOnUnlock`). Deep-copies `database`'s group tree
    /// before storing it — `database` here is (or is about to become) the
    /// live session's mutable `state`, and `KdbxGroup` is a class, so storing
    /// the reference as-is would let a later in-place `mutate()` silently
    /// mutate this "last written" snapshot too. Hops onto `persistQueue`
    /// synchronously so every read/write of either property — whether from
    /// here or from `persist(_:)`'s background closure — happens on that one
    /// serial queue, with no lock required.
    private func recordSuccessfulWrite(_ data: Data, database: KdbxDatabase) {
        let snapshot = KdbxDatabase(
            rootGroup: database.rootGroup.deepCopy(),
            deletedObjects: database.deletedObjects,
            recycleBinGroupUUID: database.recycleBinGroupUUID
        )
        persistQueue.sync {
            self.lastSuccessfullyWrittenBytes = data
            self.lastSuccessfullyWrittenDatabase = snapshot
        }
    }

    private func persist(_ db: KdbxDatabase) {
        guard let sessionPassword else { return }
        // Deep-copy the group tree synchronously (main thread, no concurrent
        // writer yet) so the background save operates on a fully independent
        // snapshot instead of the live, still-mutable `rootGroup` reference.
        let snapshot = KdbxDatabase(
            rootGroup: db.rootGroup.deepCopy(),
            deletedObjects: db.deletedObjects,
            recycleBinGroupUUID: db.recycleBinGroupUUID
        )
        let generation = beginLocalWrite()
        persistQueue.async { [weak self, fileStore, syncEngine] in
            guard let self else { return }

            // Logically identical to what's already on disk (and, if
            // attached, already synced) — skip both the KDF derivation +
            // write and the sync round-trip. Compared as `KdbxDatabase`
            // values (see its `Equatable` doc comment), NOT as serialized
            // bytes: `save(password:cipher:compression:)` mints fresh random
            // KDF salt/IV/inner-stream-key material on every call, so two
            // serializations of identical content are essentially never
            // byte-identical — a raw-bytes comparison here would never fire.
            // Safe to read `lastSuccessfullyWrittenDatabase` here: we're on
            // `persistQueue`, the only queue that ever touches it.
            if snapshot == self.lastSuccessfullyWrittenDatabase {
                self.finishLocalWrite(generation: generation, result: .wrote)
                DispatchQueue.main.async { [weak self] in
                    self?.hasDirtyLocalChanges = false
                    self?.lastSaveError = nil
                }
                return
            }

            let data: Data
            do {
                data = try snapshot.save(password: sessionPassword, cipher: .aes256, compression: .gzip)
            } catch {
                let message = String(localized: "Failed to save changes: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
                self.finishLocalWrite(generation: generation, result: .failed(message))
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = message
                }
                return
            }

            do {
                try fileStore.save(data: data)
            } catch {
                let message = String(localized: "Failed to save changes: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
                self.finishLocalWrite(generation: generation, result: .failed(message))
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = message
                }
                return
            }
            self.lastSuccessfullyWrittenBytes = data
            self.lastSuccessfullyWrittenDatabase = snapshot
            // The local file is durable from here; the quit-time flush does not wait for the sync below.
            self.finishLocalWrite(generation: generation, result: .wrote)

            guard let syncEngine else {
                DispatchQueue.main.async { [weak self] in
                    self?.hasDirtyLocalChanges = false
                    self?.lastSaveError = nil
                }
                return
            }
            do {
                _ = try syncEngine.sync(local: snapshot, password: sessionPassword, cipher: .aes256, compression: .gzip)
                DispatchQueue.main.async { [weak self] in
                    self?.hasDirtyLocalChanges = false
                    self?.lastSaveError = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.hasDirtyLocalChanges = false
                    self?.lastSaveError = String(localized: "Local save completed, but sync failed: \(String(describing: error))", comment: "Save error alert; the argument is the underlying error")
                }
            }
        }
    }
}
