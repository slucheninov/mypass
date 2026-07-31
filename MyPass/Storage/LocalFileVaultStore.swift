import Foundation

/// Primary storage when the user opened an existing `.kdbx` file (security-scoped file bookmark).
final class LocalFileVaultStore: VaultPrimaryStorage {
    private let fileURL: URL
    private let holdsSecurityScope: Bool
    private let queue = DispatchQueue(label: "com.tentens.mypass.LocalFileVaultStore")

    var vaultURL: URL { fileURL }
    var primaryVaultFileURL: URL? { fileURL }

    init(bookmarkData: Data) throws {
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

    func save(data: Data) throws {
        try queue.sync {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
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
