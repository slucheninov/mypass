import Foundation
import MyPassKit

enum EntrySearch {
    static func matches(entry: KdbxEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystacks = [entry.title, entry.login, entry.url, entry.notes]
        return haystacks.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    static func allEntries(in group: KdbxGroup) -> [KdbxEntry] {
        group.entries + group.subgroups.flatMap { allEntries(in: $0) }
    }

    static func entries(in group: KdbxGroup, matching query: String) -> [KdbxEntry] {
        guard !query.isEmpty else {
            return group.entries
        }
        return allEntries(in: findRoot(from: group)).filter { matches(entry: $0, query: query) }
    }

    private static func findRoot(from group: KdbxGroup) -> KdbxGroup {
        // KdbxGroup has no parent pointer by design (see design spec); global search
        // therefore always searches from whichever group reference is handed in as "the tree root".
        // EntryListView always passes the database's rootGroup here, so this is a passthrough.
        group
    }
}
