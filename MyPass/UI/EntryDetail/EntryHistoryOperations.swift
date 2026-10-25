import Foundation
import MyPassKit

enum EntryHistoryOperations {
    /// Appends `stored` (the version currently persisted in the vault) to `entry.history`.
    /// Shared by restore and by bridge writes that overwrite an entry in place, so there is
    /// exactly one place that decides what a history item looks like.
    static func appendSnapshot(of stored: KdbxEntry, to entry: inout KdbxEntry) {
        var snapshot = stored
        snapshot.history = [] // history entries never carry their own history, per design
        entry.history = stored.history
        entry.history.append(snapshot)
    }

    static func restoreVersion(_ version: KdbxEntry, into entry: inout KdbxEntry) {
        let current = entry
        entry.fields = version.fields
        entry.lastModificationTime = Date()
        entry.lastAccessTime = Date()
        appendSnapshot(of: current, to: &entry)
    }

    static func clearHistory(on entry: inout KdbxEntry) {
        entry.history = []
        entry.lastModificationTime = Date()
    }
}
