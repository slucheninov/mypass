import Foundation

public final class InMemoryStorageBackend: StorageBackend {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedModificationDate: Date?

    /// When non-nil, `write(_:)` throws this error instead of storing data.
    /// Used by SyncEngine network-failure tests.
    public var writeError: Error?

    public init(initialData: Data? = nil) {
        storedData = initialData
        storedModificationDate = initialData != nil ? Date() : nil
    }

    public func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError {
            throw writeError
        }
        storedData = data
        storedModificationDate = Date()
    }

    public func modificationDate() throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedModificationDate
    }

    public func exists() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedData != nil
    }
}
