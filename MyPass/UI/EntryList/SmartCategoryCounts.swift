import Foundation
import MyPassKit

enum SmartCategoryCounts {
    static func countDisplay(for category: SmartCategory, database: KdbxDatabase) -> String {
        switch category {
        case .security:
            return "—"
        case .favorites:
            return String(favoritesCount(in: database))
        case .all:
            return String(allCount(in: database))
        case .codes:
            return String(codesCount(in: database))
        case .passkeys:
            return String(EntryCategoryFilter.entries(for: .passkeys, in: database).count)
        case .addresses:
            return String(EntryCategoryFilter.entries(for: .addresses, in: database).count)
        case .cards:
            return String(cardsCount(in: database))
        case .notes:
            return String(notesCount(in: database))
        case .deleted:
            return String(deletedCount(in: database))
        }
    }

    private static func allEntries(in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
    }

    private static func allCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }.count
    }

    private static func codesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            guard let secret = $0.totpSecretBase32 else { return false }
            return !secret.isEmpty
        }.count
    }

    private static func cardsCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.entryType == .card && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func notesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.entryType == .notes && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func favoritesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func deletedCount(in database: KdbxDatabase) -> Int {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return 0 }
        return bin.entries.count
    }
}
