import Foundation

/// Opt-in capability for `StorageBackend` implementations that can surface
/// unresolved conflicting versions of their remote file — currently only
/// `iCloudBackend` (iCloud Drive's `NSFileVersion` conflict-version
/// mechanism has no equivalent for `LocalFolderBackend`/`SFTPBackend`, which
/// never produce a second, parallel version of the same path). `SyncEngine`
/// checks for this conformance via `as?` before each sync pass, so adding
/// it doesn't touch the base `StorageBackend` protocol (Task 1) or require
/// any change to backends that don't need it.
public protocol ConflictResolvingStorageBackend {
    /// Folds any unresolved conflict versions into a single merged version
    /// via `merge` (called once per conflict version, `(runningMerged,
    /// conflictVersionData) -> newMerged`), writes the result back as the
    /// current version, and marks every conflict version resolved. Returns
    /// `false` (no-op, `merge` never called) when there was nothing to
    /// resolve.
    func resolveConflictVersions(merge: (Data, Data) throws -> Data) throws -> Bool
}
