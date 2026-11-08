import MyPassKit

enum RecentEntriesQuery {
    static func recent(in database: KdbxDatabase, limit: Int = 5) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            // The menu bar popover only knows how to show and copy a login. Notes, cards,
            // addresses and files would open the login form with empty fields, so they are
            // excluded here at the source. Entries without a type field (KeePassXC) read as
            // `.login` via `entryType`.
            .filter { $0.entryType == .login }
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
            .sorted { $0.lastAccessTime > $1.lastAccessTime }
            .prefix(limit)
            .map { $0 }
    }
}
