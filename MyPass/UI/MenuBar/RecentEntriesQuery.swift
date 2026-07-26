import MyPassKit

enum RecentEntriesQuery {
    static func recent(in database: KdbxDatabase, limit: Int = 5) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
            .sorted { $0.lastAccessTime > $1.lastAccessTime }
            .prefix(limit)
            .map { $0 }
    }
}
