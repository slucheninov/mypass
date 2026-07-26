import Foundation
import MyPassKit

enum EntryCategoryFilter {
    static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] {
        let all = EntrySearch.allEntries(in: database.rootGroup)
        switch category {
        case .all:
            return all.filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .favorites:
            return [] // stub until KDBX favorite field exists
        case .codes:
            return all.filter {
                guard let secret = $0.totpSecretBase32 else { return false }
                return !secret.isEmpty
            }
        case .security:
            return all // callers must not use Security for filtering; kept for completeness
        case .deleted:
            guard let binUUID = database.recycleBinGroupUUID,
                  let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return [] }
            return bin.entries
        }
    }
}
