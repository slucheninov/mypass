import Foundation
import SyncKit

struct VaultFileStore {
    let directory: URL
    let backupCount: Int
    private let queue = DispatchQueue(label: "com.tentens.mypass.VaultFileStore")

    init(directory: URL, backupCount: Int = 10) {
        self.directory = directory
        self.backupCount = backupCount
    }

    var vaultURL: URL {
        directory.appendingPathComponent("vault.kdbx")
    }

    private var backupDirectory: URL {
        directory.appendingPathComponent("backups")
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
            try backupCurrentVaultIfPresent()
            try atomicWrite(data: data, to: vaultURL)
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    private func backupCurrentVaultIfPresent() throws {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let backupURL = backupDirectory.appendingPathComponent("vault-\(timestamp).kdbx")
        let existingData = try Data(contentsOf: vaultURL)
        try existingData.write(to: backupURL, options: .atomic)
        try rotateBackups()
    }

    private func rotateBackups() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupDirectory.path) else { return }
        let entries = try fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
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

extension VaultFileStore: VaultPrimaryStorage {}

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
