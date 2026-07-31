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
    private let backupCount: Int

    init(
        bookmarkData: Data,
        relativePath: String = "vault.kdbx",
        localBackupDirectory: URL,
        backupCount: Int = 10
    ) throws {
        self.backend = try iCloudBackend(root: .userFolder(bookmark: bookmarkData), relativePath: relativePath)
        self.localBackupDirectory = localBackupDirectory
        self.backupCount = backupCount
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

    func save(data: Data) throws {
        // Best-effort: an evicted iCloud placeholder or a slow network can make
        // the pre-save backup read throw `downloadTimedOut`. The backup is a
        // nice-to-have, not the authoritative write — it must never block
        // `backend.write(data)` below, so failures here are swallowed rather
        // than propagated.
        try? backupCurrentContentIfPresent()
        try backend.write(data)
    }

    private func backupCurrentContentIfPresent() throws {
        guard let existingData = try backend.read() else { return }
        try FileManager.default.createDirectory(at: localBackupDirectory, withIntermediateDirectories: true)
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let backupURL = localBackupDirectory.appendingPathComponent("vault-\(timestamp).kdbx")
        try existingData.write(to: backupURL, options: .atomic)
        try rotateBackups()
    }

    private func rotateBackups() throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: localBackupDirectory, includingPropertiesForKeys: [.creationDateKey])
        let sorted = try entries.sorted { lhs, rhs in
            let l = try lhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            let r = try rhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            return l < r
        }
        guard sorted.count > backupCount else { return }
        for url in sorted.prefix(sorted.count - backupCount) {
            try fm.removeItem(at: url)
        }
    }

    var primaryVaultFileURL: URL? { nil }

    func deleteVaultFileIfPresent() throws {
        // No-op for iCloud Drive storage
    }
}
