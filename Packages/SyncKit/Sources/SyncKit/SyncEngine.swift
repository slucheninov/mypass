import Foundation
import MyPassKit

/// What kind of sync cycle actually happened — surfaced mainly so `VaultSession`
/// (Task 7) and tests can distinguish "nothing to merge" from "a real
/// three-way merge occurred" (in which case the merged database must replace
/// the caller's in-memory/on-disk state).
public enum SyncResult {
    /// The remote backend did not exist yet (first sync ever) — local was
    /// uploaded as-is, with no merge to perform.
    case uploadedInitial
    /// The remote existed and was unchanged since our last successful sync
    /// — local was re-uploaded directly, with no merge to perform.
    case uploadedDirect
    /// The remote existed and had changed since our last successful sync —
    /// remote was downloaded, merged with local via `MergeEngine.merge`, and
    /// the merged result was uploaded. Carries the merged database so the
    /// caller can adopt it as the new in-memory/on-disk state.
    case merged(KdbxDatabase)
}

public enum SyncEngineError: Error {
    /// Reserved for a future backend whose `read()` can return non-nil-but-
    /// undecodable bytes in a way that must be distinguished from "no data
    /// at all" — not thrown by the current implementation.
    case remoteDataUndecodable
}

/// Orchestrates one download-if-changed → merge → atomic-upload cycle
/// against a single remote `StorageBackend`. Pure with respect to `local`
/// (never mutates the caller's value); all I/O and state live in `remote`
/// and `checkpointStore`.
public final class SyncEngine {
    private let remote: StorageBackend
    private let checkpointStore: SyncCheckpointStore

    public init(remote: StorageBackend, checkpointStore: SyncCheckpointStore) {
        self.remote = remote
        self.checkpointStore = checkpointStore
    }

    public func sync(
        local: KdbxDatabase,
        password: String,
        cipher: KdbxCipher,
        compression: KdbxCompression
    ) throws -> SyncResult {
        // Fold any pending iCloud-style conflict versions into `remote`'s
        // current content BEFORE the normal download/merge/upload cycle
        // below — closes the design spec's NSFileVersion requirement
        // (Phase 3 Self-Review gap). No-ops for any backend that doesn't
        // conform to `ConflictResolvingStorageBackend` (i.e. everything
        // except `iCloudBackend`), preserving "any StorageBackend is
        // pluggable" with zero special-casing for those backends.
        if let conflictResolvingRemote = remote as? ConflictResolvingStorageBackend {
            _ = try conflictResolvingRemote.resolveConflictVersions { currentData, conflictData in
                let currentDatabase = try KdbxDatabase.open(data: currentData, password: password)
                let conflictDatabase = try KdbxDatabase.open(data: conflictData, password: password)
                let merged = MergeEngine.merge(local: currentDatabase, remote: conflictDatabase)
                return try merged.save(password: password, cipher: cipher, compression: compression)
            }
        }

        let localData = try local.save(password: password, cipher: cipher, compression: compression)

        guard try remote.exists() else {
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedInitial
        }

        let remoteModificationDate = try remote.modificationDate()
        let lastKnownCheckpoint = try checkpointStore.loadCheckpoint()

        if remoteModificationDate == lastKnownCheckpoint {
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedDirect
        }

        guard let remoteData = try remote.read() else {
            // Remote reported `exists() == true` but returned no data on
            // read — nothing to merge against, so treat it the same as a
            // fresh remote.
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedInitial
        }
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        let mergedDatabase = MergeEngine.merge(local: local, remote: remoteDatabase)
        let mergedData = try mergedDatabase.save(password: password, cipher: cipher, compression: compression)
        try remote.write(mergedData)
        try checkpointStore.saveCheckpoint(try remote.modificationDate())
        return .merged(mergedDatabase)
    }
}
