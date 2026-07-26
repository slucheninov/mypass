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

    private let fileStore: VaultFileStore

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

    init(fileStore: VaultFileStore, syncEngine: SyncEngine? = nil) {
        self.fileStore = fileStore
        self.syncEngine = syncEngine
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
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
        state = .locked
        sessionPassword = nil
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
