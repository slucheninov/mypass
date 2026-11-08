import Foundation
import MyPassKit

enum EntrySearch {
    /// `includeAttachmentNames` is true only for the in-app search. The browser bridge shares
    /// this function and must not let a query probe file names it cannot otherwise see.
    static func matches(entry: KdbxEntry, query: String, includeAttachmentNames: Bool = false) -> Bool {
        guard !query.isEmpty else { return true }
        var haystacks = [entry.title, entry.login, entry.url, entry.notes, entry.notesBody]
        // Attachment names are not secret (the detail pane shows them unblurred), so in the app
        // any kind can be found by the name of a file it carries.
        if includeAttachmentNames {
            haystacks += entry.attachments.map(\.name)
        }
        if entry.entryType == .address {
            let address = entry.address
            haystacks += KdbxEntry.addressFields.map { address[keyPath: $0.1] }
        }
        return haystacks.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    static func allEntries(in group: KdbxGroup) -> [KdbxEntry] {
        let own = PasswordGeneratorHistoryStore.isHistoryGroup(group) ? [] : group.entries
        return own + group.subgroups.flatMap { allEntries(in: $0) }
    }

    static func entries(in group: KdbxGroup, matching query: String, includeAttachmentNames: Bool = false) -> [KdbxEntry] {
        guard !query.isEmpty else {
            return group.entries
        }
        return allEntries(in: findRoot(from: group)).filter { matches(entry: $0, query: query, includeAttachmentNames: includeAttachmentNames) }
    }

    private static func findRoot(from group: KdbxGroup) -> KdbxGroup {
        // KdbxGroup has no parent pointer by design (see design spec); global search
        // therefore always searches from whichever group reference is handed in as "the tree root".
        // EntryListView always passes the database's rootGroup here, so this is a passthrough.
        group
    }
}
