import Foundation

/// Persists the remote backend's `modificationDate()` as it stood right
/// after our own last successful upload, so `SyncEngine` can tell "remote is
/// unchanged since our last sync" (skip merge, just re-upload local) apart
/// from "remote changed since then" (download + merge is required).
public protocol SyncCheckpointStore {
    func loadCheckpoint() throws -> Date?
    func saveCheckpoint(_ date: Date?) throws
}

public final class UserDefaultsSyncCheckpointStore: SyncCheckpointStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.mypass.sync.lastRemoteModificationDate") {
        self.defaults = defaults
        self.key = key
    }

    public func loadCheckpoint() throws -> Date? {
        // `UserDefaults.double(forKey:)` returns 0 both for "the key holds a
        // real 0" and "the key is missing" — track presence explicitly via
        // `object(forKey:)` instead of trusting that ambiguity.
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: key))
    }

    public func saveCheckpoint(_ date: Date?) throws {
        guard let date else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: key)
    }
}

public final class InMemorySyncCheckpointStore: SyncCheckpointStore {
    private var checkpoint: Date?

    public init(initialCheckpoint: Date? = nil) {
        checkpoint = initialCheckpoint
    }

    public func loadCheckpoint() throws -> Date? { checkpoint }
    public func saveCheckpoint(_ date: Date?) throws { checkpoint = date }
}
