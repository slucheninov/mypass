import Foundation
import MyPassKit

enum RecycleBinEntryFilter {
    static func isInRecycleBin(_ entry: KdbxEntry, database: KdbxDatabase) -> Bool {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID })
                ?? findGroup(uuid: binUUID, in: database.rootGroup) else { return false }
        // Walk the bin's whole subtree, not just its direct entries — a sync peer or
        // third-party .kdbx import could nest an entry inside a subgroup of the bin,
        // and that entry must still be recognized as deleted.
        return EntrySearch.allEntries(in: bin).contains(where: { $0.uuid == entry.uuid })
    }

    private static func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == uuid { return group }
        for sub in group.subgroups {
            if let found = findGroup(uuid: uuid, in: sub) { return found }
        }
        return nil
    }
}
