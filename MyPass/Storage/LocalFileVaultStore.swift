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
    let backupManager: VaultBackupManager
    private let queue = DispatchQueue(label: "com.tentens.mypass.LocalFileVaultStore")

    var vaultURL: URL { fileURL }
    var primaryVaultFileURL: URL? { fileURL }
    var vaultBackupManager: VaultBackupManager? { backupManager }

    init(bookmarkData: Data, localBackupDirectory: URL, backupManager: VaultBackupManager? = nil) throws {
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
        self.backupManager = backupManager ?? VaultBackupManager(directory: localBackupDirectory)
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
            let fileURL = self.fileURL
            backupManager.snapshotIfDue {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                return try Data(contentsOf: fileURL)
            }
            try data.write(to: fileURL)
        }
    }

    func deleteVaultFileIfPresent() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

enum LocalFileVaultStoreError: Error {
    case staleBookmark
    case accessDenied
}
