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
}

final class VaultSession: ObservableObject {
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

    /// `true` while a debounced `touchAccess` persist is still waiting to run.
    /// Exposed so tests can assert that starting a migration cancels it.
    var hasPendingTouchAccessPersist: Bool {
        guard let touchAccessPersistWorkItem else { return false }
        return !touchAccessPersistWorkItem.isCancelled
    }

    init(fileStore: VaultPrimaryStorage, syncEngine: SyncEngine? = nil, iCloudPrimaryFallbackActive: Bool = false) {
        self.fileStore = fileStore
        self.syncEngine = syncEngine
        self.iCloudPrimaryFallbackActive = iCloudPrimaryFallbackActive
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
        fileStore.primaryVaultFileURL?.path ?? "Path unavailable"
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
    func updatePrimaryStore(_ newStore: VaultPrimaryStorage) {
        fileStore = newStore
        iCloudPrimaryFallbackActive = false
        wireRemoteChangeHandler(on: newStore)
        persistQueue.sync {
            self.lastSuccessfullyWrittenBytes = nil
            self.lastSuccessfullyWrittenDatabase = nil
        }
    }

    /// Design spec's external-change handling: reload-and-merge when another
    /// device/process touches the same iCloud Drive file. Wired centrally here
    /// — both at `init` and on every later `updatePrimaryStore` swap — so an
    /// in-session switch to iCloud (`VaultLocationChangeSheet`) keeps working
    /// without every call site having to remember to re-wire it. A `.local`
    /// store is a no-op since `VaultFileStore` has no such notification.
    private func wireRemoteChangeHandler(on store: VaultPrimaryStorage) {
        guard let iCloudStore = store as? ICloudDriveVaultStore else { return }
        iCloudStore.onRemoteChange = { [weak self] in
            self?.triggerBackgroundSync()
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
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
        hasDirtyLocalChanges = true
        persist(db)
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
        guard case .unlocked(let db) = state else { return }
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
        guard case .unlocked(let db) = state else { return }
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

        persistQueue.async {
            let result = Result {
                try service.migrate(
                    local: snapshot,
                    password: password,
                    remote: remote,
                    strategy: strategy
                )
            }
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
            lastSaveError = "Failed to sync vault: \(error)"
            return db
        }
        guard case .merged(let mergedDatabase) = result else { return db }
        do {
            let data = try mergedDatabase.save(password: password, cipher: .aes256, compression: .gzip)
            try fileStore.save(data: data)
            recordSuccessfulWrite(data, database: mergedDatabase)
        } catch {
            lastSaveError = "Failed to save merged changes locally: \(error)"
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
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Failed to save changes: \(error)"
                }
                return
            }

            do {
                try fileStore.save(data: data)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Failed to save changes: \(error)"
                }
                return
            }
            self.lastSuccessfullyWrittenBytes = data
            self.lastSuccessfullyWrittenDatabase = snapshot

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
                    self?.lastSaveError = "Local save completed, but sync failed: \(error)"
                }
            }
        }
    }
}
