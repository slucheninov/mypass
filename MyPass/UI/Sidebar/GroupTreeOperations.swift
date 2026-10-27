import Foundation
import MyPassKit

enum GroupTreeOperations {
    @discardableResult
    static func addGroup(named name: String, emoji: String?, to root: KdbxGroup) -> KdbxGroup {
        let now = Date()
        var newGroup = KdbxGroup(
            uuid: UUID(), name: name, iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [], subgroups: []
        )
        newGroup.emoji = emoji
        root.subgroups.append(newGroup)
        root.lastModificationTime = now
        return newGroup
    }

    static func updateGroup(withID id: UUID, name: String, emoji: String?, in root: KdbxGroup) -> Bool {
        guard let group = findGroup(uuid: id, in: root) else { return false }
        let now = Date()
        group.name = name
        group.emoji = emoji
        group.lastModificationTime = now
        return true
    }

    static func deleteGroup(
        withID id: UUID,
        in root: KdbxGroup,
        deletedObjects: inout [KdbxDeletedObject],
        recycleBinGroupUUID: inout UUID?
    ) -> Bool {
        guard id != root.uuid else { return false }
        guard let group = findGroup(uuid: id, in: root) else { return false }
        if isTheRecycleBin(group, recycleBinGroupUUID: recycleBinGroupUUID) { return false }

        let bin = recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinGroupUUID)
        let now = Date()

        for var entry in collectEntriesInSubtree(group) {
            removeEntry(withID: entry.uuid, from: root)
            entry.locationChanged = now
            bin.entries.append(entry)
            deletedObjects.append(KdbxDeletedObject(uuid: entry.uuid, deletionTime: now))
        }

        for subgroup in collectGroupsInSubtree(group) {
            deletedObjects.append(KdbxDeletedObject(uuid: subgroup.uuid, deletionTime: now))
        }

        guard removeGroupNode(withID: id, from: root) else { return false }
        root.lastModificationTime = now
        return true
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

    private static func removeGroupNode(withID id: UUID, from group: KdbxGroup) -> Bool {
        if let index = group.subgroups.firstIndex(where: { $0.uuid == id }) {
            group.subgroups.remove(at: index)
            return true
        }
        for subgroup in group.subgroups {
            if removeGroupNode(withID: id, from: subgroup) { return true }
        }
        return false
    }

    private static func collectGroupsInSubtree(_ group: KdbxGroup) -> [KdbxGroup] {
        [group] + group.subgroups.flatMap { collectGroupsInSubtree($0) }
    }

    private static func collectEntriesInSubtree(_ group: KdbxGroup) -> [KdbxEntry] {
        group.entries + group.subgroups.flatMap { collectEntriesInSubtree($0) }
    }

    @discardableResult
    private static func removeEntry(withID entryID: UUID, from group: KdbxGroup) -> Bool {
        if let index = group.entries.firstIndex(where: { $0.uuid == entryID }) {
            group.entries.remove(at: index)
            return true
        }
        for subgroup in group.subgroups {
            if removeEntry(withID: entryID, from: subgroup) { return true }
        }
        return false
    }
}

extension GroupTreeOperations {
    /// The name WRITTEN to the vault for a Recycle Bin group. It is stored data (and one of the
    /// names `isRecycleBinGroup` recognises), so it stays English forever and is never localized;
    /// the UI shows `recycleBinDisplayName` instead.
    static let recycleBinGroupName = "Recycle Bin"

    /// The localized label shown in the UI for the Recycle Bin. A computed property on purpose
    /// (not a stored constant) so it is resolved against the app's language when used.
    static var recycleBinDisplayName: String {
        String(localized: "Recycle Bin", comment: "Name shown for the Recycle Bin group in the sidebar and group lists")
    }

    /// What the UI shows for a group name. Vault-originated names are shown exactly as stored;
    /// only the Recycle Bin (identified like everywhere else by `isTheRecycleBin`: the tracked
    /// UUID wins, the name check is only the fallback when no UUID is tracked) gets the localized
    /// label. The stored name is untouched, so a file saved in one language still reads
    /// "Recycle Bin" when opened in another. Every place that renders a group name goes through
    /// this, so a group called "Recycle Bin" that is NOT the tracked bin is shown verbatim.
    static func displayName(for group: KdbxGroup, recycleBinGroupUUID: UUID?) -> String {
        isTheRecycleBin(group, recycleBinGroupUUID: recycleBinGroupUUID) ? recycleBinDisplayName : group.name
    }
    /// Legacy name used by vaults created before the English UI migration.
    static let legacyRecycleBinGroupName = "Корзина"

    static func isRecycleBinGroup(_ group: KdbxGroup) -> Bool {
        group.name == recycleBinGroupName || group.name == legacyRecycleBinGroupName
    }

    /// Whether this group is the vault's Recycle Bin for UI filtering.
    /// When `recycleBinGroupUUID` is tracked, only that UUID matches; otherwise
    /// falls back to the legacy name-based check.
    static func isTheRecycleBin(_ group: KdbxGroup, recycleBinGroupUUID: UUID?) -> Bool {
        if let binUUID = recycleBinGroupUUID {
            return group.uuid == binUUID
        }
        return isRecycleBinGroup(group)
    }

    static func subtreeGroupIDs(of group: KdbxGroup) -> Set<UUID> {
        Set(collectGroupsInSubtree(group).map(\.uuid))
    }

    /// Returns a group ID suitable as the default for create/edit pickers — never the Recycle Bin.
    static func clampedDefaultGroupID(_ candidate: UUID, in root: KdbxGroup, recycleBinGroupUUID: UUID?) -> UUID {
        if let binUUID = recycleBinGroupUUID, candidate == binUUID {
            return root.uuid
        }
        if let group = findGroup(uuid: candidate, in: root), isRecycleBinGroup(group) {
            return root.uuid
        }
        return candidate
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
        let created = addGroup(named: recycleBinGroupName, emoji: nil, to: root)
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

    static func selectableGroups(in root: KdbxGroup, excludingRecycleBin recycleBinGroupUUID: UUID?) -> [KdbxGroup] {
        flattenGroups(root).filter { group in
            !isTheRecycleBin(group, recycleBinGroupUUID: recycleBinGroupUUID)
                && !PasswordGeneratorHistoryStore.isHistoryGroup(group)
        }
    }

    private static func flattenGroups(_ group: KdbxGroup) -> [KdbxGroup] {
        [group] + group.subgroups.flatMap(flattenGroups)
    }

    /// Removes the entry from wherever it currently lives and records a
    /// tombstone for sync — unlike `softDeleteEntry`, it does NOT land in the
    /// Recycle Bin. Used for permanent purges (e.g. "Delete Permanently…").
    @discardableResult
    static func permanentlyDeleteEntry(withID entryID: UUID, in root: KdbxGroup, deletedObjects: inout [KdbxDeletedObject]) -> Bool {
        guard removeEntry(withID: entryID, from: root) else { return false }
        deletedObjects.append(KdbxDeletedObject(uuid: entryID, deletionTime: Date()))
        return true
    }

    /// Permanently removes every entry (and any stray subgroups) inside the
    /// Recycle Bin, tombstoning each for sync. The bin group itself stays.
    /// A safe no-op when the bin is missing or already empty.
    static func emptyRecycleBin(in root: KdbxGroup, deletedObjects: inout [KdbxDeletedObject], recycleBinGroupUUID: UUID?) {
        guard let binUUID = recycleBinGroupUUID, let bin = findGroup(uuid: binUUID, in: root) else { return }
        let now = Date()

        for entry in collectEntriesInSubtree(bin) {
            deletedObjects.append(KdbxDeletedObject(uuid: entry.uuid, deletionTime: now))
        }
        for subgroup in bin.subgroups {
            for groupID in collectGroupsInSubtree(subgroup).map(\.uuid) {
                deletedObjects.append(KdbxDeletedObject(uuid: groupID, deletionTime: now))
            }
        }

        bin.entries.removeAll()
        bin.subgroups.removeAll()
    }
}
