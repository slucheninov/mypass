import Foundation
import MyPassKit

enum EntryCategoryFilter {
    static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] {
        let all = EntrySearch.allEntries(in: database.rootGroup)
        switch category {
        case .all:
            return all.filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .favorites:
            return all.filter { $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .codes:
            return all.filter {
                guard let secret = $0.totpSecretBase32, !secret.isEmpty else { return false }
                return !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
            }
        case .cards:
            return all.filter { $0.entryType == .card && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .notes:
            return all.filter { $0.entryType == .notes && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .security:
            return all // callers must not use Security for filtering; kept for completeness
        case .deleted:
            guard let binUUID = database.recycleBinGroupUUID,
                  let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return [] }
            return bin.entries
        }
    }
}
