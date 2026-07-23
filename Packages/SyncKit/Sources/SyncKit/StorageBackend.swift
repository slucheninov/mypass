import Foundation

public protocol StorageBackend {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func modificationDate() throws -> Date?
    func exists() throws -> Bool
}
