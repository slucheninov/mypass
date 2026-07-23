import Foundation

public enum LocalFolderBackendError: Error {
    case staleBookmark
}

public final class LocalFolderBackend: StorageBackend {
    private let folderURL: URL
    private let filename: String

    public init(bookmarkData: Data, filename: String = "vault.kdbx") throws {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            throw LocalFolderBackendError.staleBookmark
        }
        self.folderURL = url
        self.filename = filename
    }

    public static func createBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private var fileURL: URL {
        folderURL.appendingPathComponent(filename)
    }

    public func read() throws -> Data? {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return try? Data(contentsOf: fileURL)
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func write(_ data: Data) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            try atomicWrite(data: data, to: fileURL)
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        try atomicWrite(data: data, to: fileURL)
    }

    public func modificationDate() throws -> Date? {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return try readModificationDate()
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        return try readModificationDate()
    }

    public func exists() throws -> Bool {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func readModificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = folderURL.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
