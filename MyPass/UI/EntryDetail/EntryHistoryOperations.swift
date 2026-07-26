import Foundation
import MyPassKit

enum EntryHistoryOperations {
    static func restoreVersion(_ version: KdbxEntry, into entry: inout KdbxEntry) {
        var snapshot = entry
        snapshot.history = [] // history entries never carry their own history, per design
        entry.fields = version.fields
        entry.lastModificationTime = Date()
        entry.lastAccessTime = Date()
        entry.history.append(snapshot)
    }

    static func clearHistory(on entry: inout KdbxEntry) {
        entry.history = []
        entry.lastModificationTime = Date()
    }
}
