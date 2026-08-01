import Foundation

/// Primary storage when the user opened an existing `.kdbx` file (security-scoped file bookmark).
final class LocalFileVaultStore: VaultPrimaryStorage {
    private let fileURL: URL
    private let holdsSecurityScope: Bool
    /// Directory backups are written to — deliberately NOT next to `fileURL`:
    /// the security-scoped bookmark grants access to that one exact file,
    /// not its containing directory, so writing sibling backup files there
    /// would risk violating the sandbox grant. This mirrors
    /// `ICloudDriveVaultStore`'s `localBackupDirectory`, which exists for
    /// the same reason (it doesn't own the iCloud file's directory either).
    private let localBackupDirectory: URL
    private let backupCount: Int
    private let queue = DispatchQueue(label: "com.tentens.mypass.LocalFileVaultStore")

    var vaultURL: URL { fileURL }
    var primaryVaultFileURL: URL? { fileURL }

    init(bookmarkData: Data, localBackupDirectory: URL, backupCount: Int = 10) throws {
        var isStale = false
        guard !bookmarkData.isEmpty,
              let url = try? URL(
                  resolvingBookmarkData: bookmarkData,
                  options: .withSecurityScope,
                  relativeTo: nil,
                  bookmarkDataIsStale: &isStale
              ),
              !isStale else {
            throw LocalFileVaultStoreError.staleBookmark
        }
        self.fileURL = url
        let accessGranted = url.startAccessingSecurityScopedResource()
        guard accessGranted else {
            throw LocalFileVaultStoreError.accessDenied
        }
        self.holdsSecurityScope = true
        self.localBackupDirectory = localBackupDirectory
        self.backupCount = backupCount
    }

    deinit {
        if holdsSecurityScope {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    static func createFileBookmark(for fileURL: URL) throws -> Data {
        try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func load() throws -> Data? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }
    }

    /// Writes directly to `fileURL` — no sibling temp file, no directory
    /// creation. The security-scoped bookmark this store was constructed
    /// from grants access to exactly `fileURL`, not its containing
    /// directory (which may be anywhere the user chose, e.g. their
    /// Desktop). The temp-file-then-`replaceItemAt` dance `VaultFileStore`/
    /// `ICloudDriveVaultStore` use is safe for them because they own and
    /// created that directory themselves; here it would write and rename a
    /// second path the bookmark never granted access to, and
    /// `replaceItemAt` additionally swaps in a new inode, which can
    /// invalidate the file-scoped sandbox extension entirely. A single
    /// direct `Data.write(to:)` is already effectively atomic at the OS
    /// level for the size of file a KDBX vault is.
    func save(data: Data) throws {
        try queue.sync {
            try? backupCurrentContentIfPresent()
            try data.write(to: fileURL)
        }
    }

    func deleteVaultFileIfPresent() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Best-effort: mirrors `ICloudDriveVaultStore.backupCurrentContentIfPresent`
    /// — snapshots the current on-disk content into `localBackupDirectory`
    /// (a directory this store fully owns, unlike `fileURL`'s own directory)
    /// before it gets overwritten, then rotates to the last `backupCount`.
    /// Swallowed by the `try?` at the call site: the backup is a
    /// nice-to-have, not the authoritative write, and must never block the
    /// actual save.
    private func backupCurrentContentIfPresent() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let existingData = try Data(contentsOf: fileURL)
        try FileManager.default.createDirectory(at: localBackupDirectory, withIntermediateDirectories: true)
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let backupURL = localBackupDirectory.appendingPathComponent("vault-\(timestamp).kdbx")
        try existingData.write(to: backupURL, options: .atomic)
        try rotateBackups()
    }

    private func rotateBackups() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localBackupDirectory.path) else { return }
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
}

enum LocalFileVaultStoreError: Error {
    case staleBookmark
    case accessDenied
}
