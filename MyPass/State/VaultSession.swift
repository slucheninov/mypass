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

    /// `true` while a debounced `touchAccess` persist is still waiting to run.
    /// Exposed so tests can assert that starting a migration cancels it.
    var hasPendingTouchAccessPersist: Bool {
        guard let touchAccessPersistWorkItem else { return false }
        return !touchAccessPersistWorkItem.isCancelled
    }

    init(fileStore: VaultPrimaryStorage, syncEngine: SyncEngine? = nil) {
        self.fileStore = fileStore
        self.syncEngine = syncEngine
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
    }

    func loadVaultData() throws -> Data? {
        try fileStore.load()
    }

    func unlock(password: String) throws {
        if let existingData = try fileStore.load() {
            let db = try KdbxDatabase.open(data: existingData, password: password)
            state = .unlocked(db)
            sessionPassword = password
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
    func updatePrimaryStore(_ newStore: VaultPrimaryStorage) {
        fileStore = newStore
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

    func save(password: String) throws {
        guard case .unlocked(let db) = state else {
            throw VaultSessionError.notUnlocked
        }
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        try fileStore.save(data: data)
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
        persist(db)
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
        } catch {
            lastSaveError = "Failed to save merged changes locally: \(error)"
        }
        return mergedDatabase
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
        persistQueue.async { [fileStore, syncEngine] in
            do {
                let data = try snapshot.save(password: sessionPassword, cipher: .aes256, compression: .gzip)
                try fileStore.save(data: data)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Failed to save changes: \(error)"
                }
                return
            }
            guard let syncEngine else {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = nil
                }
                return
            }
            do {
                _ = try syncEngine.sync(local: snapshot, password: sessionPassword, cipher: .aes256, compression: .gzip)
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Local save completed, but sync failed: \(error)"
                }
            }
        }
    }
}
