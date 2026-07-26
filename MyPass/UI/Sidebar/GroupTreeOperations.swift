import Foundation
import MyPassKit

enum GroupTreeOperations {
    @discardableResult
    static func addSubgroup(named name: String, to parent: KdbxGroup) -> KdbxGroup {
        let now = Date()
        let newGroup = KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [], subgroups: [])
        parent.subgroups.append(newGroup)
        parent.lastModificationTime = now
        return newGroup
    }

    @discardableResult
    static func removeSubgroup(withID id: UUID, from root: KdbxGroup) -> Bool {
        if let index = root.subgroups.firstIndex(where: { $0.uuid == id }) {
            root.subgroups.remove(at: index)
            return true
        }
        for subgroup in root.subgroups {
            if removeSubgroup(withID: id, from: subgroup) { return true }
        }
        return false
    }

    @discardableResult
    static func moveEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool {
        guard let (sourceGroup, entryIndex) = findEntryLocation(entryID: entryID, in: root) else { return false }
        guard let destinationGroup = findGroup(uuid: destinationGroupID, in: root) else { return false }
        var entry = sourceGroup.entries.remove(at: entryIndex)
        let now = Date()
        entry.locationChanged = now
        destinationGroup.entries.append(entry)
        sourceGroup.lastModificationTime = now
        destinationGroup.lastModificationTime = now
        return true
    }

    static func entryLocation(entryID: UUID, in root: KdbxGroup) -> (group: KdbxGroup, index: Int)? {
        findEntryLocation(entryID: entryID, in: root)
    }

    private static func findEntryLocation(entryID: UUID, in group: KdbxGroup) -> (KdbxGroup, Int)? {
        if let index = group.entries.firstIndex(where: { $0.uuid == entryID }) {
            return (group, index)
        }
        for subgroup in group.subgroups {
            if let found = findEntryLocation(entryID: entryID, in: subgroup) { return found }
        }
        return nil
    }

    private static func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == uuid { return group }
        for subgroup in group.subgroups {
            if let found = findGroup(uuid: uuid, in: subgroup) { return found }
        }
        return nil
    }
}

extension GroupTreeOperations {
    static let recycleBinGroupName = "Recycle Bin"
    /// Legacy name used by vaults created before the English UI migration.
    static let legacyRecycleBinGroupName = "Корзина"

    static func isRecycleBinGroup(_ group: KdbxGroup) -> Bool {
        group.name == recycleBinGroupName || group.name == legacyRecycleBinGroupName
    }

    @discardableResult
    static func recycleBinGroup(in root: KdbxGroup, recycleBinGroupUUID: inout UUID?) -> KdbxGroup {
        if let uuid = recycleBinGroupUUID, let existing = findGroup(uuid: uuid, in: root) {
            return existing
        }
        if let existingByName = root.subgroups.first(where: { isRecycleBinGroup($0) }) {
            recycleBinGroupUUID = existingByName.uuid
            return existingByName
        }
        let created = addSubgroup(named: recycleBinGroupName, to: root)
        recycleBinGroupUUID = created.uuid
        return created
    }

    @discardableResult
    static func softDeleteEntry(withID entryID: UUID, in root: KdbxGroup, deletedObjects: inout [KdbxDeletedObject], recycleBinGroupUUID: inout UUID?) -> Bool {
        guard let (sourceGroup, index) = findEntryLocation(entryID: entryID, in: root) else { return false }
        var entry = sourceGroup.entries.remove(at: index)
        entry.locationChanged = Date()
        let bin = recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinGroupUUID)
        bin.entries.append(entry)
        deletedObjects.append(KdbxDeletedObject(uuid: entryID, deletionTime: Date()))
        return true
    }

    @discardableResult
    static func restoreEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool {
        moveEntry(withID: entryID, to: destinationGroupID, in: root)
    }
}
