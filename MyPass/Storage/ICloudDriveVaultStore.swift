import Foundation
import SyncKit

/// The vault's primary storage when the configured `VaultLocation` is iCloud
/// Drive: wraps `iCloudBackend` (which already handles `NSFileCoordinator`,
/// download materialisation, and conflict-version resolution) and adds the
/// same local snapshot-backup rotation `VaultFileStore` does, so
/// `BackupsSettingsPane`'s "keep last N" setting behaves identically
/// regardless of which primary location is active.
final class ICloudDriveVaultStore: VaultPrimaryStorage {
    private let backend: iCloudBackend
    private let localBackupDirectory: URL
    let backupManager: VaultBackupManager

    init(
        bookmarkData: Data,
        relativePath: String = "vault.kdbx",
        localBackupDirectory: URL,
        backupManager: VaultBackupManager? = nil
    ) throws {
        self.backend = try iCloudBackend(root: .userFolder(bookmark: bookmarkData), relativePath: relativePath)
        self.localBackupDirectory = localBackupDirectory
        self.backupManager = backupManager ?? VaultBackupManager(directory: localBackupDirectory)
    }

    /// Fires when another device/process changes the iCloud Drive file while
    /// this store is alive. Forwarded from the underlying `iCloudBackend`.
    var onRemoteChange: (() -> Void)? {
        get { backend.onRemoteChange }
        set { backend.onRemoteChange = newValue }
    }

    func load() throws -> Data? {
        try backend.read()
    }

    /// Forwards to `iCloudBackend.readNewestAvailableBytes()` — the LWW read
    /// `VaultSession.reloadPrimaryFromRemoteIfChanged()` uses instead of
    /// `load()` so any unresolved iCloud conflict versions are folded in
    /// (newest wins) before the bytes are handed back.
    func loadNewestBytes() throws -> Data? {
        try backend.readNewestAvailableBytes()
    }

    func save(data: Data) throws {
        // Best-effort: an evicted iCloud placeholder or a slow network can make
        // the pre-save backup read throw `downloadTimedOut`. The backup is a
        // nice-to-have, not the authoritative write — it must never block
        // `backend.write(data)` below, so failures here are recorded by the
        // manager (and shown in Settings) rather than propagated.
        backupManager.snapshotIfDue { try backend.read() }
        try backend.write(data)
    }

    var primaryVaultFileURL: URL? { backend.vaultFileURL }
    var vaultBackupManager: VaultBackupManager? { backupManager }

    func deleteVaultFileIfPresent() throws {
        try backend.deleteFileIfPresent()
    }
}
