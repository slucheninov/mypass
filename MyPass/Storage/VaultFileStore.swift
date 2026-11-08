import Foundation
import SyncKit

struct VaultFileStore {
    let directory: URL
    let backupManager: VaultBackupManager
    private let queue = DispatchQueue(label: "com.tentens.mypass.VaultFileStore")

    init(directory: URL, backupManager: VaultBackupManager? = nil) {
        self.directory = directory
        self.backupManager = backupManager ?? VaultBackupManager(directory: directory.appendingPathComponent("backups"))
    }

    var vaultURL: URL {
        directory.appendingPathComponent("vault.kdbx")
    }

    func load() throws -> Data? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: vaultURL.path) else {
                return nil
            }
            return try Data(contentsOf: vaultURL)
        }
    }

    func save(data: Data) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Best-effort and non-throwing: a backup failure is logged and recorded by the
            // manager (Settings shows it) but must never block the authoritative write.
            backupManager.snapshotIfDue { [vaultURL] in
                guard FileManager.default.fileExists(atPath: vaultURL.path) else { return nil }
                return try Data(contentsOf: vaultURL)
            }
            try atomicWrite(data: data, to: vaultURL)
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}

extension VaultFileStore: VaultPrimaryStorage {
    var vaultBackupManager: VaultBackupManager? { backupManager }
    var primaryVaultFileURL: URL? { vaultURL }

    func deleteVaultFileIfPresent() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: vaultURL.path) else { return }
            try FileManager.default.removeItem(at: vaultURL)
        }
    }
}

extension VaultFileStore: StorageBackend {
    func read() throws -> Data? { try load() }
    func write(_ data: Data) throws { try save(data: data) }

    func exists() throws -> Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    func modificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return nil }
        return try vaultURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
